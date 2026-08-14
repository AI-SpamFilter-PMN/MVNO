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

Android softphones (Linphone/mizuDroid) dial `+2015…`/`015…`/`00…`-prefixed
E.164/national forms, but `usrloc`/`auth_db` keep AoRs as **bare `15XXXXXXXXX`
MSISDNs** (the 11-digit national mobile with the leading `0` stripped — e.g.
`0155…` is stored `155…`). Kamailio's `dialplan` module rewrites the R-URI user
(`$rU`) in `route[NORMALIZE]` **before every `lookup("location")`** so
`+2015559998888` routes to the same registered `15559998888` account. The rules
live in the `dialplan` table of `state/kamailio/kamailio.db` (bind-mounted at
`/etc/kamailio/db`). NEON/HLR/call-log records keep the true national `015…`
form; the dialplan bridges that to the stored `15…` AoR **without rewriting any
data** (NEON/production is read-only and never modified).

Rules (dpid=4, `match_op=1` POSIX, first-match-wins by `pr`). Canonical stored
`15…` is 11 digits: `1` + `[5-9]` + `[0-9]{9}`.

| pr | match_exp | repl_exp | Effect |
|----|-----------|----------|--------|
| 1 | `^\+20(1[5-9][0-9]{9})$` | `\1` | `+2015559998888` (E.164) → `15559998888` |
| 2 | `^\+?(1[5-9][0-9]{9})$` | `\1` | `+15559998888` (US-style plus, Linphone) and bare `15559998888` → `15559998888` |
| 3 | `^0(1[5-9][0-9]{9})$` | `\1` | `015559998888` (national `0`-leading) → `15559998888` |
| 4 | `^00(20)?(1[5-9][0-9]{9})$` | `\2` | `002015559998888` / `0015559998888` (`00` international) → `15559998888` |

**Fallback (never 404 on a missing rule):** if no rule matches (`dp_translate`
returns false), `$rU` is left **verbatim** and `lookup("location")` proceeds as
before — a genuinely unknown number 404s, but a dialplan gap never does, and no
client behaviour is ever silently rewritten. An invalid dial that cannot be
canonicalized (e.g. `+205559998888`, a `+20` number that *drops* the national
`1`) is left verbatim and 404s rather than being silently rewritten to a wrong
number.

**Re-seed deterministically (idempotent):**
```bash
bash scripts/seed-dialplan.sh                                   # live stack DB
KAMAILIO_DB=/tmp/copy.db bash scripts/seed-dialplan.sh          # on a copy/test
```
It `DELETE`s only `dpid=4` rows in a single transaction and re-inserts them (and
it is referenced from the `loadmodule "dialplan.so"` comment in
`configs/kamailio/kamailio.cfg`). After reseeding run
`podman restart mvno-kamailio` (the dialplan module caches rules at startup).

**Per-client dialing behavior (verified ≤2026-08):**

| Client | How it dials | Dialplan as dialed | Covered |
|--------|--------------|--------------------|---------|
| **Linphone (Android)** | E.164 `+2015559998888` / `+15559998888` (dial-as-entered) / bare | `+2015559998888` → pr1, `+15559998888` → pr2, bare → pr2 | ✅ |
| **mizuDroid (Android)** | national `015559998888` / `00…` / bare | `0155…` → pr3, `0020…`/`001…` → pr4, bare → pr2 | ✅ |
| **SipClient (desktop)** | bare MSISDN (RFC-3261, digest `15559998888@host`) | bare → pr2 identity | ✅ |
| **baresip/test rigs** | bare MSISDN | bare → pr2 identity | ✅ |

> **Explicitly unsupported (safety default — all 404 cleanly, never misroute):**
> * `011…` US/NA international-access prefix — no rule; passed through verbatim, 404s unless a matching AoR is registered. Add a rule (`^011(20)?(1[5-9][0-9]{9})$` → `\2`) if a client is ever configured to emit it.
> * `tel:`-URI dialing (SIP R-URI carrying `tel:+2015…`) — `$rU` would carry the literal `tel:` scheme; no rule matches; 404.
> * Star-codes / `*#` feature vocab (e.g. `**21*15559998888#`) — no matching; 404.
> * Spacing/hyphens/punctuation inside a digit string — patterns are `^$`-anchored digit-only; 404.
> * Non-Egypt country code (e.g. `+4515…`) — pr1 hard-codes `+20`; 404 (the rig is Egypt-only; such a number has no AoR anyway).

`route[NORMALIZE]` sits ahead of **both** `lookup("location")` call sites
(bare-INVITE/LOCATION and the MESSAGE path) and is skipped for
OPTIONS/CANCEL/ACK (all handled earlier in `request_route`).

**Sender (`From:`) normalization for SMS interception (Issue 8.56, 2026-08-14):**
`route[INTERCEPT_SMS]` ALSO normalizes `$fU` (the sender) to a bare MSISDN
before building the intercept payload — clients that emit `+`/`00`/`0`-prefixed
`From:` (Java SipClient, mizuDroid, Linphone intl mode) would otherwise look up
`+1555…` against the bare-MSN subscriber DB, read balance 0, and be wrongly
BLOCKED as "Prepaid balance exhausted". The same prefix table applies
(`+20…`→strip 3, `+1555…`→strip 1, `00[20]…`→strip 2, `0…`→strip 1). The
recipient (`$rU`) was already handled by the dialplan above.

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
make up                       # 37 containers (compose), offline-first
make seed-mongo               # Open5GS 5G subscribers — AFTER up (execs into mongodb)
bash scripts/testing/live_demo.sh   # 13-step end-to-end gate
```

One-command cold start (≡ the three `make` steps above): `make bootstrap`.
`make up` alone does **not** create the subscriber DBs or seed Open5GS — on a
fresh box the SMS auth / balance-403 / HLR lookups and 5G UE registration would
fail without `init-db` + `seed-mongo`.
