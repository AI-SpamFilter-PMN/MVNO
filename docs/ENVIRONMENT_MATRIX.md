# MVNO Core — Supported Environment Matrix

This document is the **authoritative portability contract** for running the MVNO core stack.
It is the single source of truth for what OS / architecture / runtime / kernel features are
required, and what will *not* work. Teammates and graders: read this before `make up`.

Run `./scripts/preflight.sh` to auto-verify these requirements on your host.

---

## 1. Supported target (verified)

| Dimension | Requirement | Notes |
|---|---|---|
| **OS** | Linux (any modern distro) | macOS / Windows / Docker Desktop are **not** supported for the full stack. |
| **Architecture** | amd64 (x86_64) | arm64 (Apple Silicon) requires a full source rebuild of all custom images + the Vosk native JNI lib (untested). |
| **Container runtime** | rootless **Podman** + the `podman compose` plugin (Docker Compose v2 compat) | Docker Engine on Linux also works for most services, but the rootless Podman socket path is the canonical one used by the Vector log shipper (see §4). |
| **Kernel: `/dev/net/tun`** | required | 5G SA UPF + UERANSIM pass `/dev/net/tun` + `NET_ADMIN` + `SYS_PTRACE` — unavailable on Docker Desktop (macOS/Windows). |
| **Kernel: SCTP** | required (`sctp` module loadable) | AMF↔gNB NGAP (`:38412`) and the 2G `osmo-stp` M3UA/SIGTRAN both ride SCTP. On macOS/Windows SCTP does not exist. Linux: `sudo modprobe sctp`. |
| **Kernel: multicast** | required for the 2G virtual-Um path | `osmocom-bb virtphy` ↔ `osmo-bts-virtual` use UDP multicast `239.193.23.1:4729`; some cloud/VM bridges disable multicast. |
| **Host CLI tools** | `sqlite3`, `nc`, `curl`, `python3`, `podman` | `make init-db` needs `sqlite3`; `vty.sh` needs `nc`; the demo runbook needs `curl`+`python3`. |

## 2. Not supported (will fail or be limited)

- **macOS / Windows / Docker Desktop:** the 5G SA core (tun + SCTP) and the 2G twin (SCTP + multicast) cannot run. `bootstrap.sh` can still *vendor* images on macOS, but the stack cannot execute.
- **arm64 (Apple Silicon):** the vendored amd64 image tarballs and the Vosk native JNI will not load/run; rebuild every custom image from source (`docker-compose.build.yml`) — untested.
- **Rootful Docker on macOS/Windows:** no `/dev/net/tun`, no SCTP, no rootless socket — same blockers as above.

## 3. Host port 5060 conflict (canonical Kamailio host port = 5066)

- The MVNO Kamailio is host-mapped to **`5066:5060/udp`**. A host-level service (here: **Asterisk**, pid bound to `0.0.0.0:5060/udp`) owns `5060`.
- Therefore the optional `MVNO_PUBLISH_5060` extra publish is **default-off and blocked on this host** — a rootless container cannot grab `5060` while Asterisk holds the wildcard bind.
- **Teammate SIP clients must target `127.0.0.1:5066`** (the canonical MVNO Kamailio host port). See `docs/INTEGRATION_CONTRACT.md`.

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
make init-db                  # SQLite subscriber DBs
make up                       # 27 containers, offline-first
bash scripts/testing/demo_runbook.sh   # 13-step end-to-end gate
```
