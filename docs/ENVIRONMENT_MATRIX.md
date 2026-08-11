# MVNO Core — Supported Environment Matrix

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
This document is the **authoritative portability contract** for running the MVNO core stack.
It is the single source of truth for what OS / architecture / runtime / kernel features are
required, and what will *not* work. External clients and reviewers: read this before `make up`.

Run `./scripts/preflight.sh` to auto-verify these requirements on your host.

---

## 1. Supported target (verified)

| Dimension | Requirement | Notes |
|---|---|---|
| **OS** | Linux (any modern distro) | macOS / Windows / Docker Desktop are **not** supported for the full stack. |
| **Architecture** | amd64 (x86_64) | arm64 (Apple Silicon) requires a full source rebuild of all custom images + the Vosk native JNI lib (untested). |
| **Container runtime** | rootless **Podman** + the `podman compose` plugin (Docker Compose v2 compat) | Docker Engine on Linux also works for most services, but the rootless Podman socket path is the canonical one used by the Vector log shipper (see Section 4). |
| **Kernel: `/dev/net/tun`** | required | 5G SA UPF + UERANSIM pass `/dev/net/tun` + `NET_ADMIN` + `SYS_PTRACE` — unavailable on Docker Desktop (macOS/Windows). |
| **Kernel: SCTP** | required (`sctp` module loadable) | AMF↔gNB NGAP (`:38412`) and the 2G `osmo-stp` M3UA/SIGTRAN both ride SCTP. On macOS/Windows SCTP does not exist. Linux: `sudo modprobe sctp`. |
| **Kernel: multicast** | required for the 2G virtual-Um path | `osmocom-bb virtphy` ↔ `osmo-bts-virtual` use UDP multicast `239.193.23.1:4729`; some cloud/VM bridges disable multicast. |
| **Host CLI tools** | `sqlite3`, `nc`, `curl`, `python3`, `podman` | `make init-db` needs `sqlite3`; `vty.sh` needs `nc`; live_demo.sh needs `curl`+`python3`. |

## 2. Not supported (will fail or be limited)

- **macOS / Windows / Docker Desktop:** the 5G SA core (tun + SCTP) and the 2G twin (SCTP + multicast) cannot run. `bootstrap.sh` can still *vendor* images on macOS, but the stack cannot execute.
- **arm64 (Apple Silicon):** the vendored amd64 image tarballs and the Vosk native JNI will not load/run; rebuild every custom image from source (`docker-compose.build.yml`) — untested.
- **Rootful Docker on macOS/Windows:** no `/dev/net/tun`, no SCTP, no rootless socket — same blockers as above.

## 3. Kamailio host SIP port (canonical = 5060)

- The MVNO Kamailio is host-published as **`5060:5060/udp`** (the standard SIP port).
- On the author's original dev host a **host-level Asterisk** (since removed) held `0.0.0.0:5060/udp`, which is why earlier docs used `5066:5060/udp` and gated the 5060 publish behind a `MVNO_PUBLISH_5060` override. **That Asterisk is gone**, so the canonical published port is now directly **5060**.
- On a fresh Ubuntu host (no Asterisk, no competing SIP stack), UDP 5060 is free and Kamailio binds it directly — no override needed.
- If **another** SIP daemon happens to hold `0.0.0.0:5060/udp` on some host, stop it, or temporarily map Kamailio to a spare port (e.g. `5066:5060/udp`) — but the default/standard is **5060**.
- **External SIP clients (SipClient / Linphone / softphones) target `<host-LAN-IP>:5060`** (UDP) — or `127.0.0.1:5060` when testing on the host itself. See `docs/INTEGRATION_CONTRACT.md`.

## 3a. Kamailio number normalization (dialplan, dpid=4)

Android softphones (Linphone/mizuDroid) dial `+20`/`00`-prefixed E.164, but
`usrloc`/`auth_db` keep AoRs as **bare `15XXXXXXXXX` MSISDNs**. Kamailio's
`dialplan` module rewrites the R-URI user (`$rU`) in `route[NORMALIZE]` **before
every `lookup("location")`** so `+205559998888` routes to the same registered
`15559998888` account. The rules live in the `dialplan` table of
`state/kamailio/kamailio.db` (bind-mounted at `/etc/kamailio/db`).

Rules (dpid=4, `match_op=1` POSIX, first-match-wins by `pr`):

| pr | match_exp | repl_exp | Effect |
|----|-----------|----------|--------|
| 1 | `^\+(20)?([5-9][0-9]{9})$` | `1\2` | `+205559998888` (and `+55…`) → `15559998888` |
| 2 | `^(00)2?([5-9][0-9]{9})$` | `1\2` | `00205559998888` (mizuDroid `00` access) → `15559998888` |
| 3 | `^1([5-9][0-9]{9})$` | `1\1` | already-normalized `15559998888` → unchanged (idempotent) |
| 4 | `^15[0-9]{9}$` | `\0` | safety identity for bare `15XXXXXXXXX` (desktop dials untouched) |

**Fallback (never 404 on a missing rule):** if no rule matches (`dp_translate`
returns false), `$rU` is left **verbatim** and `lookup("location")` proceeds as
before — a genuinely unknown number 404s, but a dialplan gap never does, and no
client behaviour is ever silently rewritten.

**Re-seed deterministically (idempotent):**
```bash
bash scripts/seed-dialplan.sh                                   # live stack DB
KAMAILIO_DB=/tmp/copy.db bash scripts/seed-dialplan.sh          # on a copy/test
```
It `DELETE`s only `dpid=4` rows in a single transaction and re-inserts them (and
it is referenced from the `loadmodule "dialplan.so"` comment in
`configs/kamailio/kamailio.cfg`).

**Per-client dialing behavior (verified ≤2026-08):**

| Client | How it dials | Dialplan as dialed | Covered |
|--------|--------------|--------------------|---------|
| **Linphone (Android)** | user types `+205559998888` or bare | `+205559998888` → pr1, bare `15559998888` → pr3/4 | ✅ |
| **mizuDroid (Android)** | `00` international access, or bare | `00205559998888` → pr2, bare → pr3/4 | ✅ |
| **SipClient (desktop)** | bare MSISDN (RFC-3261, digest `15559998888@host`) | bare → pr3/4 identity | ✅ |
| **baresip/test rigs** | bare MSISDN | bare → pr3/4 identity | ✅ |

> **Explicitly unsupported (safety default):** a `011…` US/NA international-access
> prefix (if any client is configured to emit it) has **no** dialplan rule; it is
> passed through verbatim and 404s unless a matching AoR is registered — it is
> never misrouted. Add a rule in `seed-dialplan.sh` if a client needs `011`.

`route[NORMALIZE]` sits ahead of **both** `lookup("location")` call sites
(bare-INVITE/LOCATION and the MESSAGE path) and is skipped for
OPTIONS/CANCEL/ACK (all handled earlier in `request_route`).

## 4. Vector log-shipper socket (runtime-agnostic)

- The `mvno-vector` container mounts the container engine socket to read container logs.
- Canonical path (rootless Podman): `/run/user/${PODMAN_USER_UID:-1000}/podman/podman.sock`.
- Docker users override: `DOCKER_SOCK=/var/run/docker.sock podman compose up -d` (or set `DOCKER_SOCK` in a top-level `.env`).
- `scripts/up.sh` exports `PODMAN_USER_UID=$(id -u)` so Podman works out of the box; raw `docker compose up` bypasses `up.sh`, so always use `make up`.

## 5. Offline-first / version-skew guarantee

- `scripts/bootstrap.sh` vendors image tarballs under `vendor/docker/`. The tarball tags **must** match the `image:` pins in `docker-compose.yml` exactly.
- Drift gate: `./scripts/load-offline.sh --verify-tags` exits non-zero if any compose pin has no matching vendored tarball (catches silent version-skew like vendored `mongo:8.0` vs compose `mongo:7.0`).
- `scripts/up.sh` additionally runs an exact-tag gate (`podman image exists <repo:tag>`) before launch and warns loudly on drift.
- Re-vendoring requires an internet-connected Linux host: `./scripts/bootstrap.sh` (then copy `vendor/` to the air-gapped box and run `./scripts/load-offline.sh`).

## 6. Quick start (supported target)

```bash
./scripts/preflight.sh        # verify host (must be ✓ ALL CLEAR or ! WARN)
make init-db                  # SQLite subscriber DBs (Kamailio auth + balance, HLR)
make up                       # 34 containers (compose), offline-first
make seed-mongo               # Open5GS 5G subscribers — AFTER up (execs into mongodb)
bash scripts/testing/live_demo.sh   # 13-step end-to-end gate
```

One-command cold start (≡ the three `make` steps above): `make bootstrap`.
`make up` alone does **not** create the subscriber DBs or seed Open5GS — on a
fresh box the SMS auth / balance-403 / HLR lookups and 5G UE registration would
fail without `init-db` + `seed-mongo`.
