# Telecom & Cloud-Native System Issues, Root Causes, and Verification Reference (`ISSUES.md`)

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
This document is the authoritative troubleshooting, root-cause analysis, and deployment architecture reference for the MVNO Interception Core. It details every technical issue encountered across Osmocom, Kamailio, RTPEngine, Open5GS, VictoriaMetrics, Grafana, Vector, and UERANSIM, along with empirical verification steps and deployment models (Native, Containerized, and Mixed).

> **Issue Status legend** — every NEW issue (ID above the frontier marker at the
> bottom of this block) MUST carry a `* **Status**: <enum>` line and a
> `* **Verified-by**: <evidence>` line. Enums: `LL` live-log verified · `RC`
> reproduced on cold-start · `AO` audited-only (observation, not reproduced) ·
> `X` resolved (closed) by a commit hash · `C` closed non-fault (tool mishap /
> agent artifact — file under §11 Not-Issues, not here). `scripts/check-issues.sh`
> enforces this gate; legacy entries (≤ frontier) are grandfathered and surface
> as a WARN backfill queue.

> **Issue Keyword Index (SSOT)** — before filing a new issue, grep these
> keywords; if the new symptom matches an anchor, EXTEND that issue instead of
> filing a new number. `check-issues.sh` validates the map (each keyword must
> map to exactly one existing issue):
> * `glibc` → Issue 8.30
> * `baresip` → Issue 8.30
> * `rootless` → Issue 8.14
> * `bridge` → Issue 8.21
> * `watchdog` → Issue 8.39
> * `proof` → Issue 8.40
> * `msisdn` → Issue 8.41
> * `sip-register` → Issue 8.42
> * `beep` → Issue 8.43
> * `hlr` → Issue 8.44
> * `cold-start` → Issue 8.45
> * `typing` → Issue 8.52
> * `smpp` → Issue 8.55
> * `cross-client` → Issue 8.56
> * `jansson` → Issue 8.58
> * `demo-verify` → Issue 8.59
> * `reply_ok` → Issue 8.60
> * `paging` → Issue 8.61
> * `asterisk` → Issue 8.62
> * `jansson-body` → Issue 8.63
> * `nostdin` → Issue 8.64
> * `repo-root` → Issue 8.65
> * `imdn` → Issue 8.66
* `ausine-shadowing` → Issue 8.67
* `asterisk-rtp-answer` → Issue 8.68

<!-- check-issues frontier: Issue 8.68 -->

---

## 1. Architectural & Deployment Model Taxonomy

### Native vs. Containerized vs. Mixed Deployments

| Component | Native Deployment (Systemd / Scripts) | Containerized Deployment (Podman / Docker) | Mixed / Hybrid Deployment |
|---|---|---|---|
| **Osmocom (MSC/HLR)** | Installed via `apt install osmo-msc osmo-hlr`. Configs at `/etc/osmocom/`. Runs under `osmocom` user. | Built from `debian:bookworm-slim` binary packages. VTY bound to container network. | Native MSC/HLR connected to Containerized Gateway & 5GC via bridge interface. |
| **Kamailio** | Installed via `apt install kamailio`. Modules at `/usr/lib/x86_64-linux-gnu/kamailio/modules/`. | Custom Alpine 3.19 build (`mvno-kamailio`). Modules at `/usr/lib/kamailio/modules/`. | Native Kamailio bound to host port 5060, communicating with containerized RTPEngine via `127.0.0.1:22222`. |
| **RTPEngine** | Native kernel module `xt_RTPENGINE` + daemon. High packet throughput. | Userspace packet forwarding (`drachtio/rtpengine:latest`). Bound to UDP `10000-20000`. | Native kernel module with containerized signaling proxy. |
| **Open5GS 5GC** | Installed via PPA (`ppa:open5gs/latest`). Creates `ogstun` via systemd. | Single image (`mvno-open5gs:latest`) with `NET_ADMIN` cap and `/dev/net/tun` mapping. | Native UPF with containerized Control Plane NFs (AMF/SMF/NRF). |
| **UERANSIM** | Compiled from source with `cmake`. | Built on `ubuntu:24.04` GLIBC base image. | Native gNB running on test machine connecting to containerized AMF. |

### Container Security & Rootless Rules
1. **Port Privilege Boundary**: Ports $\le 1024$ require `CAP_NET_BIND_SERVICE`. In rootless Podman/Docker, container internal ports can be $5060$ or $2775$, but host mappings must avoid privileged ports unless unprivileged port start is configured in sysctl (`net.ipv4.ip_unprivileged_port_start=1024`).
2. **SELinux Volumes**: All volume mounts use the `:z` flag (e.g., `./configs/kamailio:/etc/kamailio:z`) to allow shared SELinux labeling across rootless containers.
3. **TUN Device Permission**: Open5GS UPF requires `/dev/net/tun` mapping and `cap_add: [NET_ADMIN]` to create container-internal network interfaces without requiring full host `--privileged` access.

---

## 2. Osmocom, OsmoSMSC & OsmoHLR Issues

### Issue 2.1: VTY Parser Crash (`line-vty` vs `line vty`)
* **Symptom**: OsmoMSC aborts immediately on boot with: `There is no such command. Failed to parse the config file: '/etc/osmocom/osmo-smsc.cfg'`.
* **Root Cause**: OsmoMSC VTY lexer treats `line vty` as two space-delimited tokens (`line` sub-mode, `vty` target). Hyphenated `line-vty` is unrecognized.
* **Fix**:
  ```diff
  - line-vty
  + line vty
     no login
  ```
* **Verification**:
  ```bash
  podman run --rm -v ./configs/osmocom/osmo-smsc.cfg:/etc/osmocom/osmo-smsc.cfg:z \
    mvno-osmo-smsc:latest osmo-msc -c /etc/osmocom/osmo-smsc.cfg
  ```

### Issue 2.2: MCC/MNC Block Scope Crash
* **Symptom**: Config parse error: `Error occurred during reading line: network country code 1`.
* **Root Cause**: In OsmoMSC VTY, `network country code` is a node command scoped strictly under the `network` block node.
* **Fix**:
  ```diff
  + network
     network country code 1
     mobile network code 01
     short name MVNO
     long name MVNO Interception Core
  + !
  ```

### Issue 2.3: Invalid SMPP Directive `max-pending-requests`
* **Symptom**: Config parse error inside `smpp` block.
* **Root Cause**: `max-pending-requests` is a third-party SMSC parameter not present in Osmocom VTY.
* **Fix**: Removed `max-pending-requests` from `osmo-smsc.cfg`.

### Issue 2.4: Standalone OsmoHLR Database Path & Syntax
* **Symptom**: OsmoHLR fails to start or subscriber creation commands fail.
* **Root Cause**: In OsmoHLR 1.13+, syntax changed from `subscriber create imsi N` to `subscriber imsi N create`, and SQLite WAL is managed automatically by HLR without `db-wal yes` directives.
* **Fix**: `configs/osmocom/osmo-hlr.cfg`:
  ```
  line vty
   no login

  hlr
   database /var/lib/osmocom/hlr.db
  ```

### Issue 2.5: Telnet Dependency in VTY Automated Tests
* **Symptom**: `make test-vty` fails with `telnet: command not found` when executed inside alpine/minimal containers.
* **Fix**: Replaced `telnet` CLI dependency with bash native raw TCP sockets (`/dev/tcp`):
  ```bash
  podman exec mvno-osmo-hlr bash -c \
    'exec 3<>/dev/tcp/localhost/4258; echo enable >&3; sleep 1; echo "show subscribers all" >&3; sleep 1; dd bs=1024 count=1 <&3 2>/dev/null'
  ```

---

## 3. Kamailio SIP Proxy Issues

### Issue 3.1: Debian Module Path (`mpath`) Hardcoded in Alpine Image
* **Symptom**: Kamailio exits immediately on boot: `could not load module '/usr/lib/x86_64-linux-gnu/kamailio/modules/sl.so': No such file or directory`.
* **Root Cause**: Upstream Debian configs specify `mpath="/usr/lib/x86_64-linux-gnu/kamailio/modules/"`. In Alpine Linux, modules are at `/usr/lib/kamailio/modules/`.
* **Fix**: Removed the `mpath` line entirely. Kamailio defaults to its compiled-in module path.

### Issue 3.2: Missing `kamailio-utils` Alpine Package
* **Symptom**: `loadmodule "http_client.so"` or `loadmodule "xhttp_prom.so"` fails with file not found.
* **Root Cause**: `kamailio-http` package does NOT exist in Alpine 3.19. The correct package is `kamailio-utils`.
* **Fix**: `configs/kamailio/Dockerfile`:
  ```dockerfile
  FROM alpine:3.19
  RUN apk add --no-cache kamailio kamailio-utils kamailio-sqlite
  ```

### Issue 3.3: Worker Process Proliferation (`children=4`)
* **Symptom**: Host VM memory exhaustion due to 80+ Kamailio worker processes.
* **Root Cause**: Without `children=N`, Kamailio auto-forks worker processes per host CPU core for every listening transport.
* **Fix**: Set `children=4` in `configs/kamailio/kamailio.cfg`.

### Issue 3.4: Missing `version` Table in SQLite DB for `auth_db`
* **Symptom**: `auth_db` module fails on boot: `table version missing`.
* **Root Cause**: Kamailio DB modules verify schema version against a `version` metadata table.
* **Fix**: `Makefile` `init-db` target:
  ```sql
  CREATE TABLE IF NOT EXISTS version (id INTEGER PRIMARY KEY, table_name TEXT UNIQUE, table_version INTEGER);
  INSERT OR IGNORE INTO version VALUES (1, 'version', 1);
  ```

### Issue 3.5: Host Port Binding Collision (Exit Code 255)
* **Symptom**: Kamailio container terminates silently on startup with exit status `255` and zero log output.
* **Root Cause**: Host port `5060/udp` was held by host system SIP daemons or socket proxies, causing socket bind failure (`EADDRINUSE`).
* **Fix**: Updated `docker-compose.yml` port mapping for Kamailio to `5060:5060/udp` (canonical; the earlier 5066 workaround was because a host Asterisk held 5060).

### Issue 3.6: Unauthenticated SIP INVITE Proxying (Zero-Trust Section 1.1)
* **Symptom**: Any unauthenticated SIP client could trigger policy interception calls and reach RTPEngine — no credential check on inbound `INVITE` dialogs.
* **Root Cause**: `configs/kamailio/kamailio.cfg` only enforced digest auth on `REGISTER`; the `INVITE` branch proxied straight into `route[INTERCEPT]` with no `auth_db` challenge.
* **Fix**: Added a 407 digest challenge on the `INVITE` branch in [kamailio.cfg](configs/kamailio/kamailio.cfg): `if ($au == "" && !auth_check("$fd","subscriber","1")) { auth_challenge("$fd","0"); exit; }` before `route(INTERCEPT)`. Updated [sip_traffic_sim.py](scripts/testing/sip_traffic_sim.py) with a full 407→digest→INVITE handshake (`send_sip_invite(caller, callee, password)`), and rewrote live_demo item 6 to assert the handshake still yields `403 Forbidden` for zero-balance callers. Verified live: unauth INVITE → `407 Proxy Authentication Required`; valid digest + zero balance → `403`; `REGISTER` flow unaffected.

---

## 4. RTPEngine Media Relay Issues

### Issue 4.1: Invalid `recording-format=wav` Parameter
* **Symptom**: RTPEngine ignores recording format setting; WAV files are not generated.
* **Root Cause**: `rtpengine` only supports `eth` (PCAP) or `raw` PCAP recording formats. It does not perform inline WAV encoding.
* **Fix**: Set `recording-method = fork` in `configs/rtpengine/rtpengine.conf`. Audio stream transcription is performed in-process inside `telecom-api` by `NativeVoskService.java`.

### Issue 4.2: Entrypoint `sed -i` Volume Mount Crash
* **Symptom**: RTPEngine container crashes on boot with `sed: cannot rename /etc/sedtzTmbD: Device or resource busy` (Exit 255).
* **Root Cause**: The official `drachtio/rtpengine` entrypoint attempts `sed -i` on `/etc/rtpengine.conf`. In Docker/Podman, single file volume mounts cannot be renamed by `sed`.
* **Fix**: Mount parent directory `./configs/rtpengine:/etc/rtpengine:z` in `docker-compose.yml`.

### Issue 4.3: Prometheus Metrics Enablement (`--listen-http=9900`)
* **Symptom**: VictoriaMetrics scrape target `rtpengine:9900` returned `Connection Refused`.
* **Root Cause**: In RTPEngine v9.4+, Prometheus metrics server must be explicitly enabled via CLI argument `--listen-http=9900`.
* **Fix**: Updated `docker-compose.yml` to pass `command: ["rtpengine", "--config-file=/etc/rtpengine/rtpengine.conf", "--listen-http=9900"]` and mapped port `9900:9900`. Verified `health: UP` (`20 samples scraped`).

---

## 5. Open5GS 5G Core Issues

### Issue 5.1: Missing `amf_name` and Timer Values
* **Symptom**: AMF crashes on boot: `[amf] ERROR: No amf.amf_name in '/etc/open5gs/amf.yaml'` and `No amf.time.t3512.value`.
* **Root Cause**: Open5GS v2.8.0 AMF requires explicit AMF identification and 3GPP T3512 registration timer values.
* **Fix**: `configs/open5gs/amf.yaml`:
  ```yaml
  amf_name: open5gs-amf0
  time:
    t3512:
      value: 540
  ```

### Issue 5.2: Circular PFCP Dual-Association Error Loop
* **Symptom**: UPF and SMF continuously log `[pfcp] ERROR: invalid step[0] type[2]` and `[smf] ERROR: Cannot find PFCP-Node`.
* **Root Cause**: `client:` section was enabled in both `smf.yaml` and `upf.yaml`, causing simultaneous dual-initiations and transaction collisions.
* **Fix**:
  - `smf.yaml`: `pfcp.client.upf: - address: upf` (SMF initiates association).
  - `upf.yaml`: Remove `pfcp.client` block entirely (UPF acts purely as PFCP server on `0.0.0.0:8805`).

### Issue 5.3: Inter-NF Service-Based Interface (SBI) HTTP/2 Handshake Failures
* **Symptom**: Open5GS NFs logged repeated `HTTP2 framing error during SBI handshake` when attempting NRF registration on port `7777`.
* **Root Cause**: SBI configuration stanzas omitted explicit container hostname `advertise` parameters, causing NFs to advertise unroutable internal IP addresses (`10.89.0.76:80`).
* **Fix**: Added explicit `advertise:` parameters (`advertise: amf`, `advertise: nrf`, `advertise: ausf`) across `configs/open5gs/*.yaml`.

### Issue 5.4: UDM `no_tls` SBI Framing — 3GPP Rel-16 Verification Note
* **Scope**: Verify the Open5GS UDM Service-Based Interface (SBI) HTTP/2 cleartext (h2c) framing against 3GPP Rel-16 (TS 29.500 / TS 29.501) requirements for the isolated bridge network.
* **Findings**: `configs/open5gs/udm.yaml` sets `no_tls: true` at the `default` scope and on both `udm.sbi.server` (`0.0.0.0:7777`) and `udm.sbi.client` (`nrf`, `udr`) stanzas. The identical `no_tls: true` + `advertise: <nf>` pattern is present across `amf.yaml`, `ausf.yaml`, `bsf.yaml`, `nrf.yaml`, `nssf.yaml`, `pcf.yaml`, `smf.yaml`, `udr.yaml` (UPF is exempt: it communicates via PFCP and has no SBI HTTP/2 server).
* **Conclusion**: h2c cleartext framing is compliant for a trusted, single-tenant bridge network (`mvno_net`) per TS 29.500 Section 6.1 (TLS optional when transport security is provided by the network segment). No changes required. Live evidence: `nrf` shows all NFs registered over cleartext HTTP/2; `mvno-udm`/`mvno-udr` healthy.

### Issue 5.5: `ogs_tun_set_ip()` is a No-Op on Linux — ogstun Gateway Never Configured
* **Symptom**: UPF's N6 tunnel device `ogstun` existed inside `mvno-upf` but had **no IP address and no route** (`ip addr` empty, `10.45.0.0/16` route absent). All user-plane packets written to the tun by the UPF were silently dropped by the kernel (device RX/TX counters stayed at 0). Symptom seen as "UPF receives GTP-U but no N6 write" (`[RECV] GPU-U` traces present, `ogstun` RX = 0).
* **Root Cause**: `ogs_tun_set_ip()` in Open5GS `lib/tun/linux-setup.c` is a **deliberate no-op returning `OGS_OK`** on Linux — verified identical in v2.7.7 and v2.8.0. The comment in `src/upf/gtp-path.c` states "Note that Linux will skip this configuration": on Linux the operator must configure the TUN externally (`ip tuntap add` / `ip addr add` + route). The containerized UPF entrypoint never did this, so the UPF opened `ogstun` (device created via `TUNSETIFF`) but the device had no addressing.
* **Fix**: [configs/open5gs/entrypoint.sh](configs/open5gs/entrypoint.sh) UPF branch polls for `ogstun` to appear (≤30 s), then applies:
  ```bash
  ip addr replace 10.45.0.1/16 dev ogstun
  ip -6 addr replace 2001:db8:cafe::1/48 dev ogstun
  ip link set ogstun up
  ```
  (`iproute2` added to the runtime stage of [configs/open5gs/Dockerfile](configs/open5gs/Dockerfile)).
* **Verification**: `podman exec mvno-upf ip addr show ogstun` → `inet 10.45.0.1/16`, `inet6 2001:db8:cafe::1/48`, `UP,LOWER_UP`; `ip route` → `10.45.0.0/16 dev ogstun proto kernel scope link src 10.45.0.1`. UL probe: 5 UDP packets from a UE tun reach `ogstun` RX (+165 bytes); DL probe: packets from the UPF netns reach the UE tun.

### Issue 5.6: Fresh v2.8.0 Source Rebuild Regresses SBI HTTP/2 Clients (30 s Heartbeat Death)
* **Symptom**: After rebuilding the Open5GS container from the `v2.8.0` tag source, every NF's SBI connection to the NRF died at the first heartbeat (~30-35 s after registration): `[sbi] WARNING: Error in the HTTP2 framing layer (16)` (lib/sbi/client.c:767, `CURLE_HTTP2`), followed by NRF `[nrf] WARNING: No heartbeat` → de-registration. All NFs de-registered on a fixed cadence regardless of NRF restart order.
* **Root Cause**: The freshly built daemon binaries (from-source v2.8.0 tag, verified tag peel `157f611a...` 2026-06-20 Release-19) exhibited a regressed HTTP/2 client behavior compared to the known-good 07-26 image (`mvno-open5gs:latest`, image `a2f041bbd267`). A 2×2 matrix (old/new image × NRF/client) proved: any *new-image client* fails; any *known-good client* works against either NRF. Runtime libraries were byte-identical (libcurl3-gnutls 7.88.1-10+deb12u15, libgnutls30 3.7.9-2+deb12u7, libnghttp2-14 1.52.0-1+deb12u3, libssl3 3.0.20-1~deb12u2); only the Open5GS daemon binaries differed (md5).
* **Fix**: [configs/open5gs/Dockerfile](configs/open5gs/Dockerfile) is now **layered on the known-good image** (`FROM mvno-open5gs:2.8.0-base`, a pinned re-tag of the known-good 2.8.0 image) adding only `iproute2` + the fixed `entrypoint.sh` — it does **not** rebuild Open5GS from source. The Dockerfile carries an explicit banner: do not switch the base back to a fresh source build until the HTTP/2 client regression is root-caused upstream. Rebuilt image `mvno-open5gs:2.8.0` daemon binaries now md5-match the known-good image.
* **Verification**: Full stack recreate → NRF shows 8 NF registrations, **0 de-registrations** past the 90 s heartbeat checkpoint; only a few startup-race framings (all before the settle timestamp), none after.

### Issue 5.7: SMF UE Pool Allocates the ogstun Gateway Address (10.45.0.1) to UEs
* **Symptom**: Intermittently a UE was handed `10.45.0.1/32` — the same address as the `ogstun` gateway (e.g. wave 1: ue-1=.3, ue-2=**10.45.0.1**, ue-3=.4). Traffic to `10.45.0.1:9` from that UE self-routed into its own tun, breaking probes and shadowing the real gateway.
* **Root Cause**: `configs/open5gs/smf.yaml` session stanza declared only `subnet: 10.45.0.0/16`, so the SMF's allocatable UE pool began at the subnet base — including the gateway address the UPF's ogstun uses.
* **Fix**: [configs/open5gs/smf.yaml](configs/open5gs/smf.yaml):
  ```yaml
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
      range: # UE address pool: starts at .2 so ogstun gateway .1 is never allocated to a UE
        - 10.45.0.2-10.45.0.254
      dnn: internet
  ```
* **Verification**: After recreate, UE addresses were 10.45.0.2 / 10.45.0.3 / 10.45.0.4 — `.1` never allocated across subsequent session establishments.

---

### Regression family: "5G user plane downlink dead / uplink healthy" (5.8 ↔ 5.9)
> **Durable-entry rule**: do NOT mint a new issue number per regression of this
> family. The family shares one signature — SIP works uplink but the GTP-U
> downlink never emits (`far->gnode == NULL` silent buffering, or stale gNB
> F-TEID routing) — and one durable runbook defence: the **preflight probe**
> `scripts/testing/preflight_5g.sh` (reads the LIVE `uesimtun0` IP, drives a
> UAS REGISTER over the 5G path, asserts iptables `OUTPUT dport 2152` moves)
> wired into `live_demo.sh` [5b] BEFORE any call. A probe failure prints the
> actionable fix (restart ue-1 for 5.9; restart gNB+UEs for 5.8) instead of a
> silent stale-IP timeout.

| # | Date | Signature | Root cause | Fix |
|---|------|-----------|------------|-----|
| 7.4 | earlier | UL data plane dead after partial gNB recreate | stale NGAP state | recreate gNB |
| 8.8 | earlier | "No Heartbeat from SMF" | PFCP client addr resolution | restart SMF/UPF pairing |
| 5.8 | 08-05 | downlink silent after long uptime (ogstun RX=0) | stale gNB F-TEID/GTP-U after interrupted SMF/AMF epoll | `podman restart mvno-ueransim-gnb` + UEs |
| 5.9 | 08-08 | downlink dead after UE re-register burst (ogstun TX reads reply, never emits GTP-U) | lost `UpdateSmContext` (gNB F-TEID) via SBI HTTP/2 framing error → `far->gnode == NULL` | `podman restart mvno-ueransim-ue-1` |

### Issue 5.8: 5G User-Plane SIP Path Goes Silent After Long Uptime — Stale gNB GTP-U Downlink (ogstun RX=0)
* **Symptom**: `live_demo.sh` check 5b fails on a multi-day-old stack: the UE's SIP REGISTER to `10.89.0.23:5060` via `uesimtun0` times out even though the UE tunnel exists (`10.45.0.x/32`) and AMF still reports `ran_ue = 3`. Uplink is dead end-to-end: UPF `ogstun` RX stays `0` and the POSTROUTING `MASQUERADE 10.45.0.0/16 !ogstun` rule shows `0 packets` — no UE byte ever reaches the user plane.
* **Root Cause**: The 5G core + UERANSIM containers had been running ~3 days (`StartedAt 08-03 22:32`); an external signal (compose/restart cycle at 08-05 11:34:43) interrupted the SMF/AMF event loops — both `amf.log` and `smf.log` end with `[core] ERROR: epoll failed (4:Interrupted system call)` at the same millisecond — while the processes survived. SMF/UPF PDU-session state and the **gNB's downlink F-TEID/GTP-U mappings went stale**: after restarting the UEs (fresh registration + new PDU sessions), uplink recovers (ogstun RX moves, MASQUERADE matches) and the UPF transmits SIP replies (ogstun TX increments) but they never reach the UE — the gNB still routes the downlink tunnel to the dead session.
* **Fix**: Restart the gNB first (rebuilds NGAP + all GTP tunnels), then the UEs:
  ```bash
  podman restart mvno-ueransim-gnb && sleep 8
  podman restart mvno-ueransim-ue-1 mvno-ueransim-ue-2 mvno-ueransim-ue-3
  # wait ~45 s, confirm re-registration: query=ran_ue -> 3
  ```
* **Verification**:
  ```bash
  # raw SIP probe from inside the UE — must return a 401/200, not timeout:
  podman exec mvno-ueransim-ue-1 python3 /tmp/sip_traffic_sim.py \
    --host 10.89.0.23 --port 5060 --callee 15559998888 --caller 15551234567
  # -> 'Registration failed: timed out' BEFORE; 'REGISTER 200 OK' after the fix.
  ./scripts/testing/live_demo.sh   # check 5b: 'ogstun TX +2769 bytes'; full gate 13/13 (exit 0)
  ```
* **2026-08-05 regression re-certification**: full `live_demo.sh` gate passed **13/13 (exit 0)** after the gNB+UE restart, including the 5G user-plane SIP traversal (5b), 407→digest→403 zero-balance block (6), EIR SIM-swap (7), 5G SMS interception (8), Vosk ASR + spool archive (9), SMPP bind (10), PromQL (11/13) and Grafana NOC (12).

### Issue 5.9: 5G Downlink Dead After Concurrent UE Re-Registration Burst — Lost `UpdateSmContext` (gNB F-TEID) via SBI HTTP/2 Framing Error
* **Symptom** (2026-08-08 regression): `live_demo.sh` check 5b fails: the 5G-path UAS REGISTER to `10.89.0.23:5060` from `mvno-ueransim-ue-1` times out, while UEs on sessions created moments earlier/later work. The failure signature differs from Issue 5.8: **uplink is healthy** (REGISTER reaches Kamailio; UPF `ogstun` RX/iptables INPUT `dport 2152` counts packets) and the upfd **reads the downlink reply** (`ogstun` TX increments, TUN fd read confirmed) but **never emits GTP-U** — iptables OUTPUT `dport 2152` stays at **0 packets**. No `[DROP]`/`ogs_tun_read() failed`/`No GTP Node Setup`/`No GTP Socket Setup` lines appear in `upf.log` (v2.8.0 source: `src/upf/gtp-path.c` `_gtpv1_tun_recv_common_cb` drops silently when `upf_sess_find_by_ue_ip_address()` or the DL PDR/FAR match fails; `lib/pfcp/handler.c` `ogs_pfcp_up_handle_pdr()` **buffers silently when `far->gnode == NULL`**).
* **Root Cause**: At `08-08 05:09:54` three UEs re-registered nearly simultaneously (20 s after the UPF restart). The AMF logged `Error in the HTTP2 framing layer (16)` + `ogs_sbi_client_handler() failed [-1]` at `05:09:54.172` — exactly while ue-1's `Nsmf_PDUSession_UpdateSMContext` (which carries the gNB's N3 F-TEID) was in flight to the SMF. The SMF consequently never provisioned the **downlink FAR with the gNB F-TEID** on the UPF (`far->gnode == NULL`), so downlink G-PDUs were silently buffered/dropped while uplink (whose FAR targets the N6/ogstun side, no gnode required) worked. Evidence correlation:
  - UPF session `10.45.0.3` (ue-1) added at `05:09:54.166`, **6 ms before** the AMF SBI error; `10.45.0.2` (ue-2, `05:09:33`) and `10.45.0.4` (ue-3, `05:09:54.175`) were unaffected — and only ue-1's downlink was dead.
  - AMF: `Cannot receive SBI message` / `No SmContextUpdateError [400]` at `05:10:04.175` (10 s SBI timeout); SMF: `Unknown message [214]` at `05:10:04.177`; gNB NGAP `protocol/semantic-error` at `05:10:04`.
* **Fix**: Re-establish the affected UE's PDU session (fresh PFCP Session Establishment carries the gNB F-TEID correctly):
  ```bash
  podman restart mvno-ueransim-ue-1   # re-attach -> new session/IP (e.g. 10.45.0.5)
  # wait for uesimtun0 to come up, then re-run the 5b probe with the NEW UE IP.
  ```
  No core/upf restart is needed; sessions created outside the SBI error window are healthy.
* **Verification**: after the UE restart, `iptables -L OUTPUT -nv | grep 2152` on `mvno-upf` moves from `0` to `>0` packets, `ogstun` TX increments, and the full 5b dialog (UAS REGISTER 200 OK → INVITE 407→100→180→200 OK → RTP) completes over the 5G user plane.
* **Runbook robustness fix (2026-08-08)**: `live_demo.sh` [5b] previously hardcoded ue-1's UE IP (`--bind-ip 10.45.0.8`), which went stale as UE IPs are re-allocated from the SMF pool on every attach. The runbook now reads ue-1's current `uesimtun0` IPv4 at runtime and fails fast with a clear message if the 5G session is down.
* **Measurement-rule amendment (2026-08-08 cold-start regression)**: the `OUTPUT dport 2152` counter used by `preflight_5g.sh` / the [5b] probe was a **manual debug insertion**, never part of the deployment — a cold start (UPF container recreate) wipes it, so the preflight read an empty chain and FAILed (`0->0`) even with a healthy user plane. Both documented fixes (ue-1 restart, full trio recreate) were ineffective because the data plane was fine all along. Fix: `preflight_5g.sh` now inserts the counting rule idempotently (`iptables -C ... || iptables -I OUTPUT 1 -p udp --dport 2152 -j ACCEPT`, policy ACCEPT, pure measurement) before baselining. Verified: rule removed → preflight self-inserts → REGISTER 200 OK + `OUTPUT 2152 0->2 pkts` → PASS.

---

## 6. Control-Plane & Telemetry Pipeline Operational RCA

### Issue 6.1: SQLite WAL Directory Mount Permission (`SQLITE_READONLY_DIRECTORY`)
* **Symptom**: `telecom-api` REST queries returned `balance: 0` for all subscribers, and container logs showed `[SQLITE_READONLY_DIRECTORY] Process does not have permission to create a journal file in the same directory as the database`.
* **Root Cause**: Single-file bind mount (`- ./state/kamailio.db:/etc/kamailio/kamailio.db:z`) prevented the non-root container process from creating temporary `.db-wal` and `.db-shm` lock/journal files in `/etc/kamailio/`.
* **Fix**: Updated `docker-compose.yml` to mount the parent directory (`- ./state:/etc/kamailio:z`), allowing SQLite WAL mode to create journal/shm files seamlessly.
* **Status**: X (superseded by Issue 8.12 — unified mount `./state/kamailio/kamailio.db`)

### Issue 6.2: `vmagent` Promscrape Configuration Flag Omission
* **Symptom**: VictoriaMetrics (`:8428`) and Grafana NOC Dashboards (`:3000`) rendered empty metric panels with zero active targets.
* **Root Cause**: `vmagent` container command stanza was missing `-promscrape.config=/etc/prometheus/prometheus.yml`, causing `vmagent` to run in silent mode without loading target scrape configurations. Additionally, the target hostname in `scrape.yml` was listed as `telecom-api` instead of `mvno-api`.
* **Fix**: Added `-promscrape.config=/etc/prometheus/prometheus.yml` and exposed port `8429:8429` in `docker-compose.yml`, and updated `scrape.yml` target address to `mvno-api:8080`. Verified scrape jobs resolving to **8 active scrape target instances (8/8 health: UP)** (`amf`, `smf`, `upf`, `mvno-api`, `rtpengine`, `mongodb-exporter`, `vmagent`, `victoria-metrics`). Ingested MongoDB metrics grew from 1 to **2,372 metrics** after adding `--collect-all`.

### Issue 6.3: Grafana SQLite WAL Corruption
* **Symptom**: Grafana crashes after host reboot with `database is locked` or `disk I/O error`.
* **Root Cause**: Missing `GF_DATABASE_WAL=true` in `docker-compose.yml` environment variables.
* **Fix**: Pinned image to `grafana/grafana-oss:11.6.0` and added `GF_DATABASE_WAL=true` in `docker-compose.yml`.
* **Status**: X (applied in 2026-08-01 telemetry alignment; not in initial stack compose configuration)

### Issue 6.4: PromQL Syntax Error in Grafana Stat Cards (`|| vector(0)`)
* **Symptom**: Grafana Stat Panels displayed "No data" and red parsing error icons, while time-series line graphs below rendered live values.
* **Root Cause**: Stat panel targets used non-standard `|| vector(0)` operator syntax instead of standard PromQL `default 0` fallback syntax.
* **Fix**: Replaced `|| vector(0)` with `default 0` (e.g. `sum(mvno_sms_requests_total) default 0`) across [configs/grafana/provisioning/dashboards/mvno_unified_noc.json](configs/grafana/provisioning/dashboards/mvno_unified_noc.json).

### Issue 6.5: Legacy Metric Schema Mismatches in Subsystem Dashboards
* **Symptom**: `noc_rtpengine.json` panels rendered "No data" for throughput and error rate, while `noc_telecom_api.json` and `noc_overview.json` rendered rate `0`.
* **Root Cause**: Panels queried outdated metric names (`rtpengine_packets_received_bytes_total`, `rtpengine_calls_total`) instead of exported RTPEngine 9.4 metrics (`rtpengine_bytes_total`, `rtpengine_packets_total`, `rtpengine_packet_errors_total`).
* **Fix**: Aligned panel targets across `noc_overview.json`, `noc_telecom_api.json`, and `noc_rtpengine.json` with exact Prometheus metrics exported by `mvno-api` and `rtpengine`.

---

## 7. UERANSIM 5G Radio Simulator Issues

### Issue 7.1: Alpine Glibc Symbol Relocation Error
* **Symptom**: `nr-gnb` fails to launch: `exec container process (missing dynamic library?) /usr/local/bin/nr-gnb: No such file or directory`. `ldd` reveals `__isoc23_strtol` symbol not found and `GLIBC_2.38` required.
* **Root Cause**: Prebuilt UERANSIM binaries are compiled against GLIBC 2.38. Alpine base images use `musl libc` which lacks these GLIBC symbols.
* **Fix**: Updated `configs/ueransim/Dockerfile` to `ubuntu:24.04` base image.

### Issue 7.2: Missing UERANSIM YAML Mandatory Schema Keys
* **Symptom**: `nr-gnb` and `nr-ue` report `ERROR: Field 'X' is missing` or `sessions.type` error on boot.
* **Fix**:
  - `gnb.yaml`: Added `linkIp: 0.0.0.0`, `ngapIp: 0.0.0.0`, `gtpIp: 0.0.0.0`, `ignoreStreamIds: true`.
  - `ue.yaml`: Added `sessions.type: IPv4`, `gnbSearchList`, `op`, `opType: OP`, `integrity`, `ciphering`, `integrityMaxRate`, `uacAic`, `uacAcc`.

### Issue 7.3: Spurious Second PDU Session Establishment Request → SMF 400 → Session Teardown
* **Symptom**: ~10 s after a UE's PDU session established (observed on `ue-1`, the first UE after a gNB/UE recreate), the UE's NAS sent a **second PDU Session Establishment Request** (type 193). The AMF forwarded it to the SMF via `sm-contexts/{ref}/modify`; the SMF rejected with `[smf] ERROR: Unknown message [214]` (0xD6 = PDU Session Release Command) + HTTP 400; the AMF then failed the session (`Cannot receive SBI message` → `amf_nnrf_send_session_failure_to_ran` → NGAP Error Indication `protocol/semantic-error` to the gNB). UE log: `SM forwarding failure for message type[193] ... PAYLOAD_NOT_FORWARDED`, `Received PSI value [1] is invalid, expected was [0]`, `Sending SM Cause[INVALID_PTI_VALUE]`. Result: that UE's DL data path stopped working (DL GTP-U dropped at gNB, no DRB delivery) while other UEs stayed healthy.
* **Root Cause**: UERANSIM v3.2.6 UE NAS state quirk — the UE re-sent a PDU session establishment request (with a stale/invalid PSI transaction) ~10 s after establishment; the Open5GS SMF's GSM state machine does not recognize the forwarded NAS type in that path and 400s it, and the AMF tears the session down. Not caused by deployment configuration (occurred only on the first UE after a full UERANSIM trio recreate, while ue-2/ue-3 with identical config stayed clean).
* **Fix / Workaround**: Recreate the affected UE (`podman compose up -d --force-recreate ueransim-ue-1`) to obtain a fresh session. No permanent config change required.
* **Verification**: After ue-1 recreate: UL probes delivered to `ogstun` (RX +165 bytes) and DL probes delivered to ue-1 tun (RX incremented) — full bidirectional gate PASS.

### Issue 7.4: UL Data Plane Dead After Partial gNB Recreate — Stale NGAP Contexts, gNB Silently Swallows PDU Session Resource Setup
* **Symptom**: After recreating **only** `ueransim-gnb` (single-container recreate; UEs kept running and re-attached to the new gNB), UL data died: UE tun TX counters incremented when probing `10.45.0.1:9`, but **nothing ever reached the UPF** (`[RECV] GPU-U` absent, ogstun RX stuck). The gNB logged neither RRC Reconfiguration nor DRB establishment for the UEs, and never logged `PDU session resource(s) setup`. `smf` and `upf` were silent — no F-TEID modification, no PFCP Session Modification Response.
* **Root Cause**: The partial gNB recreate left **stale NGAP contexts on the UEs** (the UEs carried UE contexts from the pre-recreate gNB instance). When the UEs sent Service Requests and the new gNB forwarded the PDU session setups, UERANSIM's `gnb/ngap/session.cpp` `handlePDUSessionResourceSetupRequest()` could not match the contexts (`findUeByNgapIdPair` returned null) and **returned silently without sending the setup response** — the exact case a code-path review of v3.2.6 source confirmed. Without the PDU Session Resource Setup Response, no RRC Reconfiguration/DRB is ever issued → no data radio → UL GTP-U never flows. Contamination is persistent: consecutive waves (AMF restart, then another gNB recreate) kept reproducing the dead path because the stale UE contexts were never cleared atomically. Note the log-order gotcha: the gNB's `PDU session resource(s) setup` log line (session.cpp:206) is emitted **after** `sendNgapUeAssociated()` (session.cpp:203), so its absence proves the setup was never answered.
* **Fix (operational rule)**: **Always recreate the whole UERANSIM trio atomically** — `podman compose up -d --force-recreate ueransim-gnb ueransim-ue-1 ueransim-ue-2 ueransim-ue-3` — never a single UERANSIM container. A full atomic recreate (05:14 wave) cleared all stale contexts: gNB logged `PDU session resource(s) setup` for every UE, SMF processed `/modify` with `IPv4[10.89.0.30]` F-TEID and answered `Session Modification Response [5gc]` (n4-handler.c:268), and the UPF re-ran `gtp_connect() [10.89.0.30]:2152` for N3.
* **Verification**: 5 UDP probes from ue-1 tun → 10.45.0.1:9: UPF logged `[RECV] GPU-U Type [255] from [10.89.0.30] : TEID[0x9fa2]` (gtp-path.c:345) with rule-match `PROTO:17 SRC:0a2d0006`; ogstun RX incremented (+165 bytes). DL: 4 UDP probes from the UPF netns (10.45.0.1:34569) → ue-1 tun IP:9 delivered (tun RX incremented). Full bidirectional gate PASS on ue-1 and DL PASS on ue-2/ue-3.

---

## 8. Podman & Docker Container Engine & Networking Issues

### Issue 8.1: Loopback (`127.0.0.1`) Isolation in Container Bridge Networks (`mvno_net`)
* **Symptom**: Inter-container communication fails with `Connection Refused` or `Network unreachable`.
* **Root Cause**: Services binding to `127.0.0.1` bind exclusively to the container's private loopback interface (`lo`).
* **Fix**: All containerized daemons MUST bind server sockets to `0.0.0.0` or container DNS hostnames.

### Issue 8.3: Missing Kamailio Outbound HTTP REST Interception Callout
* **Symptom**: Kamailio proxied incoming SIP `INVITE` dialogs directly to RTPEngine without querying `mvno-api:8080/api/v1/intercept/call` for policy authorization.
* **Root Cause**: `configs/kamailio/kamailio.cfg` did not load `http_client.so` and lacked an HTTP REST callout route.
* **Fix**: Added `loadmodule "http_client.so"` and `route[INTERCEPT]` using `http_client_query("http://mvno-api:8080/api/v1/intercept/call", ...)` before location lookup in [configs/kamailio/kamailio.cfg](configs/kamailio/kamailio.cfg).

### Issue 8.4: Open5GS SBI HTTP/2 Framing Layer (Code 16) Heartbeat De-Registration
* **Symptom**: Open5GS AMF and NFs logged `Error in the HTTP2 framing layer (16)` every 11 seconds and de-registered from NRF.
* **Root Cause**: SBI server stanzas lacked container network `advertise: <service_name>` FQDNs, causing NRF to register `0.0.0.0:80` unroutable endpoints.
* **Fix**: Added explicit `advertise: <container_name>` parameters across all 10 `configs/open5gs/*.yaml` configuration files on port `7777`.

### Issue 8.6: Open5GS WebUI Next.js Module Resolution Failure (`modules/store.js`)
* **Symptom**: HTTP 500 error on `http://localhost:9999` with `Module not found: Can't resolve 'modules/store.js' in '/usr/src/app/pages'`.
* **Root Cause**: Open5GS WebUI Next.js server bound to `127.0.0.1` inside container (blocking host port forward) and Webpack lacked `NODE_PATH=src` module resolution paths for `src/` subdirectories (`modules`, `containers`, `components`, `helpers`).
* **Fix**: Added `HOST=0.0.0.0`, `PORT=3000`, and `NODE_PATH=src` in `docker-compose.yml`, and created symlinks pointing `src/*` into `/usr/src/app/node_modules` and `/usr/src/app/pages` in [configs/open5gs/Dockerfile.webui](configs/open5gs/Dockerfile.webui).

### Issue 8.7: Open5GS WebUI React 15 JSX Transpilation & Node 18 Runtime (`ReferenceError: React is not defined`)
* **Symptom**: HTTP 500 internal server error on `http://localhost:9999` with `ReferenceError: React is not defined` at `Auth.render` or Node ESM syntax errors (`Cannot use import statement outside a module`).
* **Root Cause**: Next.js 3 compiles `pages/` but does not transpile `src/` modules imported via `NODE_PATH=src`. Node 19+ strict ESM loader threw SyntaxError on `import` statements outside modules, and React 15 JSX transpilation required `var React = require('react')` injection.
* **Fix**: Rebased container on official `node:18-bookworm-slim` base image, added Babel 7 CLI + `@babel/preset-env` + `@babel/preset-react` + `@babel/plugin-transform-class-properties` + `@babel/plugin-transform-modules-commonjs` transpilation step in [configs/open5gs/Dockerfile.webui](configs/open5gs/Dockerfile.webui), and injected `var React = require('react')` to compiled JSX files. Verified `curl http://localhost:9999` returns `HTTP 200 OK` (`<title>Open5gs - Login</title>`).

### Issue 8.8: Open5GS UPF PFCP Client Address Target Resolution (`No Heartbeat from SMF`)
* **Symptom**: System journal reported `[pfcp] WARNING: No Heartbeat from SMF` and `[smf] ERROR: Cannot find PFCP-Node: type [1] node_id NULL from [127.0.0.1]:8805`.
* **Root Cause**: `configs/open5gs/upf.yaml` lacked `pfcp.client.smf` section, defaulting PFCP client heartbeat target to loopback `127.0.0.1:8805` instead of container network hostname `smf`.
* **Fix**: Added `pfcp.client.smf: - address: smf` to [configs/open5gs/upf.yaml](configs/open5gs/upf.yaml). PFCP heartbeats between SMF and UPF are now associated and healthy across `mvno-net`.
* **Status**: X (superseded by Issue 8.10 — SMF acts as sole PFCP client initiator per 3GPP TS 29.244)

### Issue 8.9: Open5GS SBI Cleartext HTTP/2 (`no_tls: true`) Configuration Across All NFs
* **Symptom**: Open5GS NRF, AMF, SMF, and AUSF logged `nghttp2_session_mem_recv() failed (-903: Received bad client magic byte string)` and `Error in the HTTP2 framing layer (16)`.
* **Root Cause**: Open5GS SBI server stanzas default to TLS (HTTPS) unless `no_tls: true` is explicitly configured. SBI clients connecting via `http://` failed TLS framing negotiation.
* **Fix**: Added `no_tls: true` under `sbi.server` across all 9 `configs/open5gs/*.yaml` files. All NFs now register successfully with NRF.

### Issue 8.10: Open5GS UPF PFCP State Machine Dual-Initiator Collision
* **Symptom**: SMF & UPF logged `PFCP[REQ] has already been associated` and `invalid step[0] type[6]`.
* **Root Cause**: `configs/open5gs/upf.yaml` erroneously configured `pfcp.client.smf`, causing UPF to initiate PFCP association back to SMF simultaneously, colliding with SMF's PFCP association request.
* **Fix**: Removed `pfcp.client` section from [configs/open5gs/upf.yaml](configs/open5gs/upf.yaml). SMF acts as sole PFCP client initiator per 3GPP TS 29.244.

### Issue 8.11: EIR SIM-Swap Fraud State Erasure Across Cache Purges
* **Symptom**: Active SIM-swap blocks were bypassed after scheduled 10-minute cache purges or capacity eviction.
* **Root Cause**: `EirTracker.java` evaluated raw call count instead of distinct SIM insertions per IMEI, and called `imeiSwapCounter.clear()`, wiping active fraud states (`swaps > 3`).
* **Fix**: Refactored [EirTracker.java](telecom-api/src/main/java/com/mvno/intercept/subscriber/EirTracker.java) to track distinct MSISDN bindings (`ConcurrentHashMap<String, Set<String>>`) per IMEI, selectively prune low-activity entries (`removeIf(entry -> entry.getValue().size() <= 1)`), and restrict `reset()` method to test scope.

### Issue 8.12: Split-Brain SQLite Database File Mount (`kamailio` vs `telecom-api`)
* **Symptom**: Kamailio registered subscribers to `./state/kamailio.db` while `telecom-api` read from `./state/kamailio/kamailio.db`, causing subscriber data divergence.
* **Root Cause**: In `docker-compose.yml`, `kamailio` mounted single file `./state/kamailio.db:/etc/kamailio/kamailio.db:z` while `telecom-api` mounted directory `./state/kamailio:/etc/kamailio:z`.
* **Fix**: Unified volume mount in [docker-compose.yml](docker-compose.yml) for `kamailio` service to `./state/kamailio/kamailio.db:/etc/kamailio/kamailio.db:z` and updated [Makefile](Makefile) `init-db` target.

### Issue 8.13: RTPEngine PCAP vs Audio Recording Method Compatibility with Vosk ASR
* **Symptom**: Native Vosk ASR service polled for audio captures in `/var/spool/rtpengine`, while RTPEngine recorded in binary PCAP format (`recording-method=pcap`).
* **Root Cause**: RTPEngine `mr9.4` supports `recording-method=pcap|proc` and `recording-format=raw|eth` (`fork` is unsupported on this build). Unconditional `Files.deleteIfExists()` in older service builds deleted audio evidence regardless of transcription status.
* **Fix**: Maintained [rtpengine.conf](configs/rtpengine/rtpengine.conf) baseline `recording-method=pcap` and `recording-format=eth`, restricted [NativeVoskService.java](telecom-api/src/main/java/com/mvno/intercept/transcription/NativeVoskService.java) `DirectoryStream` filter to audio captures, and implemented evidence archiving to `state/spool/archived/`.

### Issue 8.17: Unauthenticated Intercept REST Endpoints (Zero-Trust Section 1.2)
* **Symptom**: `POST /api/v1/intercept/sms`, `GET /api/v1/intercept/call`, and `POST /api/v1/intercept/call` accepted requests with no credential of any kind, so any reachable client could trigger interception or read subscriber state.
* **Root Cause**: `SubscriberController` and the Kamailio `http_client_query` callout relied on network position (bridge-internal) rather than an application-layer credential.
* **Fix**: Added [ApiKeyInterceptor.java](telecom-api/src/main/java/com/mvno/intercept/config/ApiKeyInterceptor.java) + [WebConfig.java](telecom-api/src/main/java/com/mvno/intercept/config/WebConfig.java) (registered on `/api/v1/intercept/**`) with `intercept.api-key: ${X_API_KEY:mvno-demo-key-2026}` in `application.yml`; Kamailio callout switched to 4-arg `http_client_query(url, "", "X-API-Key: ...\r\n", res)` (empty post-data → GET with headers). All consumers keyed: Makefile `make test-api/test-sms/test-call` and live_demo items 4/7/8. `/actuator/*` intentionally left open for vmagent scraping. Verified live: missing/wrong key → `401`; valid key → normal flow; 3 new tests (`ApiKeyInterceptorTest`) → suite now 22/22.

### Issue 8.14: Rootless Podman Docker Socket Path Permission for Vector
* **Symptom**: Vector container failed to collect docker logs with `No such file or directory: /var/run/docker.sock`.
* **Root Cause**: Rootless Podman exposes user-level socket at `/run/user/1000/podman/podman.sock` instead of root system path `/var/run/docker.sock`.
* **Fix**: Updated `vector` volume mount in [docker-compose.yml](docker-compose.yml) to `/run/user/1000/podman/podman.sock:/var/run/docker.sock:ro,z`.

### Issue 8.15: Stale Java Container Tags in `bootstrap.sh`
* **Symptom**: Offline bootstrap save step (`bootstrap.sh --offline`) skipped saving Java image archives.
* **Root Cause**: `SAVE_IMAGES` array in `bootstrap.sh` contained stale `eclipse-temurin:25-jre` tags while `PREBUILT_IMAGES` used Java 21 LTS (`eclipse-temurin:21-jre`).
* **Fix**: Updated `SAVE_IMAGES` array tags in [scripts/bootstrap.sh](scripts/bootstrap.sh) to `eclipse-temurin-21-jre` and `maven-3.9-eclipse-temurin-21`.

### Issue 8.16: Osmocom VTY Script Container Engine Portability (`vty.sh`)
* **Symptom**: `scripts/vty.sh` hardcoded `podman` engine invocation and relied strictly on container `/dev/tcp` socket redirection.
* **Root Cause**: Non-bash container shells (Alpine/busybox) lack `/dev/tcp` socket redirection syntax, causing execution failure on minimalist images.
* **Fix**: Refactored [scripts/vty.sh](scripts/vty.sh) with container runtime auto-detection (`podman`/`docker`) and added `nc -w 3 127.0.0.1 <port>` socket redirection fallback.

### Issue 8.18: `docker build` vs `podman build` Store Divergence
* **Symptom**: A fresh `docker build` of the Open5GS container produced a different image than the previously built `podman` image — identical `Dockerfile` and context, different daemon binary md5s and different `imageId`, even though layer hashes appeared equal.
* **Root Cause**: Container engines cache differently (`docker build` separate store; `podman` may reuse a stale local cache) — the "identical layers" hash equality was broken once fresh-archive hashes were compared. This divergence was implicated in the HTTP/2 heartbeat regression hunt (Issue 5.6): the source rebuild experiment was repeated on both engines and only the source-rebuild artifacts (not engine choice) correlated with the framing failures.
* **Fix / Guidance**: Treat the image cache as non-portable across engines. Reproduce experiments on the same engine; do not validate a rebuilt image with a different engine's cache. For Phase 0 the build is frozen: `mvno-open5gs:2.8.0` is layered on the known-good `mvno-open5gs:latest` (a2f041bbd267) with only `iproute2` + `entrypoint.sh` added (Issue 5.6).
* **Verification**: `podman images` shows `mvno-open5gs:latest`/`mvno-open5gs:2.8.0`; daemon binaries inside both images md5-match after the layering fix.

### Issue 8.19: docker-compose IPAM Collision — Unpinned Static IP Grabs Another Service's Address
* **Symptom**: `telecom-api` intermittently came up without its intended static address; a concurrent container (e.g. `mongodb`) had already claimed `10.89.0.4`, and `telecom-api` grabbed a different address (e.g. `10.89.0.46`) — breaking configs that hardcode the gateway's FQDN/address.
* **Root Cause**: `docker-compose.yml` left `telecom-api` `ipv4_address` unpinned at times (or assigned last), while other services used fixed IPs; the bridge IPAM hands out addresses in order, so two services raced for the same subnet slot.
* **Fix**: [docker-compose.yml](docker-compose.yml) pins every service's `ipv4_address` explicitly in a conflict-free plan (e.g. `telecom-api: 10.89.0.46`, `mongodb: 10.89.0.4`), with the plan audited via `podman compose config` (no duplicate IP assertions).
* **Verification**: `podman compose config` exits 0; `podman exec mvno-api ip addr` shows `10.89.0.46/24`; no `Network address already in use` errors across full-stack recreates.

### Issue 8.20: Rootless Podman Has No Host Route to Container IPs — UE↔Bridge Needs UPF-Internal SNAT
* **Symptom**: `sudo ip route add 10.45.0.0/16 via 10.89.0.14` on the host fails with `Error: Nexthop has invalid gateway`; `curl http://10.89.0.46:8080/...` from the host is unreachable even though the container answers on published ports.
* **Root Cause**: Rootless Podman (pasta/slirp) keeps the compose bridge subnet `10.89.0.0/24` inside its **user network namespace** — no host interface carries it, so the host cannot route to container IPs at all. The "host route via the UPF" design (valid for rootful/native deployments) is impossible here; return traffic for anything forwarded out of `ogstun` (10.45.0.0/16) to the bridge would be dropped at the host.
* **Fix**: The UPF entrypoint ([configs/open5gs/entrypoint.sh](configs/open5gs/entrypoint.sh)) installs an idempotent SNAT rule inside the UPF netns — the whole UE→bridge round-trip stays in-netns:
  ```bash
  iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
  ```
  (`iptables` added to the Open5GS Dockerfile runtime layer; `net.ipv4.ip_forward=1` is already the container default.) Trade-off: bridge services see the UE's traffic with source `10.89.0.14` (the UPF), not the UE's `10.45.0.x`.
* **Verification**: SIP over 5G end-to-end (Phase 1 gate): sim from inside ue-1 with the kamailio `/32` routed via `uesimtun0` → REGISTER 200 OK, INVITE 407 → digest → 100 trying; Kamailio logs show the dialog from `10.89.0.14`; ogstun counters grow (~10 KB RX / ~15 KB TX per dialog pair).

### Issue 8.21: IP-SM-GW Bridge Unbounded Retry Spin on 2G→5G Delivery Failure
* **Symptom**: If a 5G destination was unreachable (e.g., UE not registered → 404) or blocked (e.g., pike 429), the bridge logged `[RETRY]` and immediately re-attempted the delivery at full CPU speed.
* **Root Cause**: `scripts/ip_sm_gw.py` logic failed to invoke `mark_attempt()` in the exception/failure branch of the 2G→5G poll loop. The row's `deliver_attempts` counter never incremented, so the SQL query `deliver_attempts < MAX_ATTEMPTS` remained true forever.
* **Fix**: Added an explicit `mark_attempt(self.sc, row["id"])` call in the failure branch. Retries are now bounded to `MAX_ATTEMPTS=5` (default). Once exhausted, the row is no longer polled.
* **Verification**: Injected SMS for an unregistered 5G UE; bridge log showed 5 `RETRY` events then stopped polling that `row_id`. `smsc.db` showed `deliver_attempts=5`.

### Issue 8.22: IP-SM-GW Bridge Tight `recv()` Loop Tripping Kamailio Pike (429 Flood)
* **Symptom**: During retry bursts, the bridge would suddenly receive `429 Too Many Requests` from Kamailio for all subsequent SIP MESSAGE attempts.
* **Root Cause**: The SIP listener `recv()` timeout was dynamically set to `0.2s` if pending rows existed. Combined with the `mark_attempt` bug (Issue 8.21), this created a tight spin-loop that exceeded Kamailio's `pike` module threshold (anti-flood).
* **Fix**: Changed `self.sip.recv(timeout=...)` to ALWAYS use `POLL_INTERVAL` (default 5s). This provides a natural backoff between delivery attempts, staying well under the pike threshold.
* **Verification**: End-to-end 2G→5G delivery (leg 1) now shows `[POLL]`, `[SEND]`, then `[DELIVERED]` with a stable cadence. Kamailio logs no longer show 429s for the bridge IP.

### Issue 8.23: 5G→2G SIP MESSAGE Relay Loops / 408 Timeout (Test Artifact)
* **Symptom**: 5G→2G SMS failed with 408 Request Timeout or infinite Kamailio relay loops when using a receiver co-located with the bridge.
* **Root Cause**: Running the UE receiver (`ims_terminal.py --mode recv`) in the same container as the bridge (`mvno-ip-sm-gw` @ `10.89.0.53`) caused source-IP ambiguity. Kamailio could not distinguish the bridge's relay leg from the receiver's response leg, leading to routing confusion.
* **Fix**: **Test methodology fix only.** Dedicated receiver containers (e.g., `ue1-recv-test` @ `10.89.0.60`) must be used for verification. This ensures clean IP separation for Kamailio's `lookup("location")` and routing logic.
* **Verification**: Verified 5G→2G leg (leg 2) using a dedicated container; bridge log showed `[RELAY] 5G->2G` → `[SMPP] SUBMIT_SM OK`.

### Issue 8.24: AI-Filter Mock Ignores Chunked Request Bodies — Every SMS Allowed (Blocked Counter Stuck at 0)
* **Symptom**: `POST /api/v1/intercept/sms` on `mvno-api` returned `{"allow":true,"reason":"Clean content"}` even when the `content` field contained the `E2E-BLOCK` marker; `mvno_sms_blocked_total` (actuator prometheus) never incremented, while direct `curl` POSTs to `mvno-ai-filter:8008/api/v1/classify` with the same marker correctly returned `allow:false`. The sms_matrix's AI-block cell could never pass.
* **Root Cause**: Spring's `RestClient` (JDK HttpClient) sends the classification POST with `Transfer-Encoding: chunked` and **no `Content-Length`** (verified on the wire: `CL=None TE=chunked`). The inline mock's `do_POST` only read `int(self.headers.get('Content-Length', 0))` bytes, so it always saw an empty body `b''` and fell into the `allow:true` branch. Diagnosed via bytecode inspection of `app.jar` (`AiFilterService` builds `content_text` from `req.content()`) plus a temporary body-logging mock variant that printed the API's actual request (`BODY-LOG b'' CT=application/json CL=None TE=chunked`).
* **Fix**: `docker-compose.yml` inline mock now parses chunked transfer-encoding (read size lines until zero chunk) before falling back to Content-Length. Config-only change; the real FastAPI classifier (AI-Filteration-System) is unaffected (chunked handled natively).
* **Verification**: Same probe now returns `{"allow":false,"reason":"Spam (E2E deterministic block)"}`, `mvno_sms_blocked_total` increments per blocked message, and `sms_matrix.sh` Cell 5 (AI-block) passes — two consecutive full runs exit 0.

### Issue 8.25: Bridge 5G→2G 200 OK Malformed (`Via: Via:`) — Kamailio Retransmit Storm & Duplicate Deliveries
* **Symptom**: A single 5G→2G SMS was relayed ~9 times (`[RELAY]` logged at exponential intervals) and delivered repeatedly to the 2G handset (`sms.txt` accumulated copies); the sending terminal never received its final response (`MESSAGE not accepted: no response`).
* **Root Cause**: `reply_ok()` in `scripts/ip_sm_gw.py` collected the relayed request's `Via:` lines **whole** (`vias = [ln.strip() ...]`) and then re-emitted them as `f"Via: {v}"`, producing an invalid `Via: Via: SIP/2.0/UDP ...` header in the 200 OK. Kamailio's tm module could not match the transaction branch, so it kept retransmitting the MESSAGE per its retransmit timer (observed 0.5s/1s/2s/4s/8s pattern). The terminal's own reply builder (which strips the prefix) was correct — only the bridge's copy was broken.
* **Fix**: Strip the header prefix when collecting (`ln.strip().split(":", 1)[1].strip()`) so the re-emitted header is a single `Via:`.
* **Verification**: Sender now prints `[+] MESSAGE delivered (digest)` (receives the final 200 OK), exactly **one** `[RELAY]` line per SMS, exactly one copy in `sms.txt`, and bridge counters move +1 only. Both `sms_matrix.sh` Cells 3/4 assert clean single-delivery behavior and pass.

### Issue 8.26: Bridge 2G-MSISDN SIP Registrations Die Silently After Hours — 5G→2G Leg Returns 404
* **Symptom**: After ~4 h of bridge uptime, the 5G→2G leg stopped working: the sending terminal got `MESSAGE not accepted: SIP/2.0 404 Not Found` while its own REGISTER succeeded, `mvno_bridge_sms_5g_to_2g_total` never moved, the bridge logged no `[RELAY]`, and the 2G handset received nothing. `sms_matrix.sh` Cell 3 failed (1 failure, 6 ok) although 2G→2G, 2G→5G, 5G→5G and the AI-block cell all passed. A live probe (fresh terminal → 15554443322) reproduced the 404 deterministically, proving Kamailio's `lookup("location")` had lost the bridge's registration of the 2G MSISDNs (usrloc memory state; `db_mode=2` write-back means the sqlite file never reflected live bindings).
* **Root Cause**: Two compounding faults in `scripts/ip_sm_gw.py` `BridgeSip.register()`:
  1. **Fixed Call-ID + restarting CSeq (true root cause, discovered Aug 3 2026)**: every registration attempt reused the same Call-ID (`bridge-reg-{msisdn}-{etag}@mvno`, where `etag = time.time()` was captured once at init) while CSeq restarted at 1/2 on each attempt. Kamailio's registrar rejects a re-REGISTER whose CSeq does not exceed the stored one — `registrar [save.c:721]: update_contacts(): invalid cseq for aor <15554443322>` + `sl_reply_error(): I'm terribly sorry…` — so a *refresh could never succeed at all*; the 2G leg always died at the first 1800 s expiry.
  2. **Slow refresh cadence**: re-registration ran only every **1500 s** (`if time.time() - last_reg > 1500`) with no fast retry, leaving a dead 2G leg for hours even after the first fault was understood as a transient.
* **Fix**: `scripts/ip_sm_gw.py` — (a) each registration attempt now uses a **fresh Call-ID and branch** (`nonce_ts = int(time.time())` embedded in `bridge-reg-{msisdn}-{nonce_ts}@mvno`), so CSeq progression is always accepted; (b) refresh every **900 s** (2× margin under the 1800 s expiry); (c) if any MSISDN's REGISTER fails, retry after **30 s** instead of a full interval and log the outcome per MSISDN.
* **Verification**: (a) 5/5 consecutive re-REGISTERs accepted from inside the bridge container (`podman exec -e SIP_PORT=5092 mvno-ip-sm-gw python3 …`) with no `invalid cseq` errors; clean re-registration across repeated Kamailio restarts; (b) bridge restart + immediate probe: `[REGISTER] … 200 OK` for both 2G MSISDNs, sender got `[+] MESSAGE delivered (digest)`, bridge logged `[RELAY]` → `[SMPP] BIND_TRANSCEIVER OK` → `[SMPP] SUBMIT_SM OK`, exactly one copy in MS1 `sms.txt`. `sms_matrix.sh` then passed **two consecutive full runs (7 ok, EXIT=0)**.


---

## 9. Master Verification & Verification Checklist

| Target / Subsystem | Command / Probe | Expected Result | Verification Status |
|---|---|---|---|
| **Spring Boot Unit Tests** | `./mvnw test` | `Tests run: 22, Failures: 0` | ✅ **PASS** |
| **Gateway Liveness** | `GET :8080/actuator/health/liveness` | `{"status":"UP"}` | ✅ **PASS** |
| **Subscriber Balance API** | `GET :8080/api/v1/intercept/subscriber/15551234567` | `{"msisdn":"15551234567","balance":100}` | ✅ **PASS** |
| **Normal VoIP Call** | `POST /api/v1/intercept/call` (`caller: 15551234567`) | `{"allow":true,"reason":"AI filter unreachable — SLA allow"}` | ✅ **PASS** |
| **Zero-Balance Call Block** | `POST /api/v1/intercept/call` (`caller: 15557654321`) | `{"allow":false,"reason":"Prepaid balance exhausted"}` | ✅ **PASS** |
| **Normal 5G SMS** | `POST /api/v1/intercept/sms` (`sender: 15551234567`) | `{"allow":true,"reason":"AI filter unreachable — SLA allow"}` | ✅ **PASS** |
| **Zero-Balance SMS Block** | `POST /api/v1/intercept/sms` (`sender: 15557654321`) | `{"allow":false,"reason":"Prepaid balance exhausted"}` | ✅ **PASS** |
| **EIR SIM-Swap Block** | >3 distinct MSISDNs on single IMEI | `{"allow":false,"reason":"EIR: SIM swap detected"}` | ✅ **PASS** |
| **SIP INVITE 407 (zero-trust Section 1.1)** | Unauthenticated `INVITE` via `sip_traffic_sim.py` | `407 Proxy Authentication Required`; digest + zero-balance → `403` | ✅ **PASS** |
| **X-API-Key 401 (zero-trust Section 1.2)** | `GET /api/v1/intercept/call` without `X-API-Key` header | `HTTP 401 Unauthorized`; valid key → normal response | ✅ **PASS** |
| **vmagent Scraper Targets** | `GET :8429/api/v1/targets` | `8/8 targets health: UP` (6 scrape jobs) | ✅ **PASS** |
| **VictoriaMetrics TSDB** | `GET :8428/api/v1/query?query=mvno_sms_requests_total` | `seriesFetched: 1`, `value: [ts, "2"]` | ✅ **PASS** |
| **ogstun N6 Gateway (Issue 5.5)** | `podman exec mvno-upf ip addr show ogstun` | `inet 10.45.0.1/16`, `inet6 2001:db8:cafe::1/48`, `UP` | ✅ **PASS** |
| **UE Pool vs Gateway (Issue 5.7)** | `podman exec mvno-ue-1 ip addr show uesimtun0` | UE in `10.45.0.2-10.45.0.254` range, **never** `10.45.0.1` | ✅ **PASS** |
| **UL Data Plane (Phase 0 gate)** | 5 UDP probes from ue-1 tun → `10.45.0.1:9` | UPF `[RECV] GPU-U Type [255] from [10.89.0.30]`; ogstun RX +165 bytes | ✅ **PASS** |
| **DL Data Plane (Phase 0 gate)** | 4 UDP probes from UPF netns `10.45.0.1:34569` → ue-1 tun IP:9 | ue-1 tun RX incremented (+4); no N3 drops | ✅ **PASS** |
| **SIP over 5G (Phase 1 gate)** | `sip_traffic_sim.py --host 10.89.0.23 --port 5060` from inside ue-1 (kamailio `/32` via `uesimtun0`) | REGISTER 200 OK + INVITE 407 → digest → 100 trying; ogstun counters grow; `mvno_call_requests_total` increments | ✅ **PASS** |
| **Open5GS WebUI Login UI** | `GET :9999/` | `HTTP 200 OK` (`<title>Open5gs - Login</title>`) | ✅ **PASS** |
| **IP-SM-GW Leg 1 (2G→5G)** | `send_db_sms.sh` 2G→5G | Bridge log: `POLL` → `SEND` → `DELIVERED`; row `sent` NOT NULL | ✅ **PASS** |
| **IP-SM-GW Leg 2 (5G→2G)** | `ims_terminal.py` 5G→2G | Bridge log: `[RELAY]` → `[SMPP] SUBMIT_SM OK` | ✅ **PASS** |
| **IP-SM-GW Bounded Retry** | Fail 2G→5G delivery (UE unregistered) | `deliver_attempts` climbs to 5 and stops; no pike 429 flood | ✅ **PASS** |
| **IMS Voice Call (media plane, Issue 8.27)** | `sip_traffic_sim.py --uas … --rtp 5` + `--rtp 6` caller | `407 → 100 → 180 → 200 OK`, ACK/BYE answered, bidirectional RTP through rtpengine, `rtpengine_packets_total > 0`, recorded pcap, `pcap_to_wav.py` (retired; now `live_tap.sh --once`) → Vosk `.txt` in spool/archived | ✅ **PASS** (Aug 3 2026) |
| **Media Plane Re-Certification (post-restart)** | UAS + caller containers (`--rtp 5/6`) after `final-timeout=300` config + rtpengine restart | caller 298 pkts / 47 680 B received by UAS (298×160); UAS 248 pkts relayed; `rtpengine_packets_total` +546, `bytes_total` +93 912 per call (1092 / 187 824 across two calls); `closed_sessions_total{reason="terminated"}` = 2 (BYE → `rtpengine_delete`); unanswered-INVITE session reclaimed by `final-timeout` (`reason="final_timeout"` = 1, ~5 min after offer — fixes the port leak); sessions 0, `ports_free` 101 after close; pcap 125 604 B per call; counters are process-local → **reset on container recreate**, measure deltas, accounting flushes on exporter tick (poll, observed 0-60 s) | ✅ **PASS** (Aug 5 2026) |
| **Post-call Transcript → AI Verdict (supervisor flow leg)** | espeak-ng real speech → 16 kHz WAV → spool → Vosk ASR → `TRANSCRIPT` classify | Vosk `{"text": "this is my first call from your man come out that suspicious transactions"}` → log `AI transcript verdict [...]: allow=true, reason='Clean content'`; `mvno_vosk_classified_total` = 1; mock TRANSCRIPT `E2E-BLOCK` → `allow:false "Spam (E2E deterministic block)"`, clean → `allow:true` | ✅ **PASS** (Aug 5 2026) |
| **Transcript BLOCKED path live (demo scam call)** | espeak-ng `"You have won a prize, call us now"` → 16 kHz WAV → spool → Vosk ASR → mock keyword rule | Vosk `{"text": "you have won an prize called us out"}` → `AI transcript verdict [...]: allow=false, reason='Spam (phishing phrase detected)'`; `mvno_vosk_blocked_total` = 1 and `mvno_vosk_classified_total` = 4 in VictoriaMetrics `:8428`; unit test `NativeVoskServiceVerdictTest` 3/3 (26/26 suite); SMS/VOICE_CALL unaffected by keyword rule; `E2E-BLOCK` still authoritative for all event types (e2e gate 7/7, demo 13/13 exit 0) | ✅ **PASS** (Aug 5 2026) |
| **Demo Gate Re-Certification (Issue 5.8)** | `./scripts/testing/live_demo.sh` after gNB + UE restart | **13/13 passed, exit 0** — incl. 5G user-plane SIP (ogstun TX +2769 B), 407→digest→403, EIR block, 5G SMS, Vosk ASR, SMPP bind, PromQL, Grafana NOC | ✅ **PASS** (Aug 5 2026) |
| **E2E SMS Matrix (AI-block)** | `./scripts/testing/sms_matrix.sh` | **ALL CELLS PASS (7 ok)** — 2G→2G, 2G→5G, 5G→2G, 5G→5G, AI-block (E2E-BLOCK → 403, `mvno_sms_blocked_total` 0→1) | ✅ **PASS** (Aug 5 2026) |


---

### Issue 8.27: IMS Voice Call INVITE Never Reaches the Callee — Media Plane Never Proven (First Completed VoIP Call)

* **Symptom**: Every historical call test (manual guide Flow E, demo [5]/[5b], earlier runs) stopped at `100 trying` — no `200 OK`, no media. `rtpengine_sessions_total`=12 (all `reason=timeout`), `rtpengine_packets_total`=0, `bytes_total`=0, spool contained zero call recordings: the RTP media plane had never carried a single packet, yet "Active RTP Sessions 0 / Media Bytes 0 B" dashboard zeros made it look healthy.
* **Root Cause** (three defects, all in `scripts/testing/sip_traffic_sim.py`):
  1. **Ephemeral registration socket**: the UAS registered via an *unbound* UDP socket, so its source port was ephemeral (e.g. `:42461`). Kamailio's `fix_nated_contact()` rewrote the stored contact to the source `IP:ephemeral-port`; `lookup("location")` matched and `t_relay()` forwarded the INVITE to a dead port — silently. The legacy terminals work because they register from their bound listen socket (source port == Contact port → no rewrite). Proven via `debug=3` trace: `lookup_helper(): contact for [15559998888] found by address` and stored contact `sip:15559998888@10.89.0.58:42461`.
  2. **Missing Record-Route echo**: the UAS's `200 OK` did not echo the INVITE's `Record-Route`, so the caller sent ACK/BYE *without* a `Route` header; Kamailio dropped them (no in-dialog handling). With the fix, the ACK/BYE R-URI was still `sip:…@localhost:5060`, which Kamailio relayed back to itself (`localhost` → `127.0.0.1:5060` loop; `rr: There is no Route HF`, request-route falls through) — fixed by addressing ACK/BYE to the callee's `Contact` from the `200 OK`.
  3. **SDP parse bug**: `_parse_sdp()` used `line.split(" ", 3)[3]` on `c=IN IP4 <ip>` (IndexError once the dialog actually completed).
* **Fix**: `register_subscriber()` now binds its socket to `(bind_ip, listen_port)` and returns it (kept open for inbound requests); `run_uas()` reuses it; UAS replies echo `Record-Route`; ACK/BYE target the `200 OK` Contact (`_parse_contact()`); `_parse_sdp()` uses split-based parsing; UAS also streams outbound RTP (from its media port) so rtpengine records both directions.
* **Pipeline component (now `scripts/testing/live_tap.sh`)**: the original `pcap_to_wav.py` (G.711 PCMU pcap→8 kHz WAV in `state/spool/`) was retired — `live_tap.sh --once <pcap>` is the certified bash extractor (`tshark → awk → xxd → ffmpeg`, zero Python), per `docs/REALTIME_AUDIO.md`. Retro-history below notes the pcap→wav name as of Aug 2026; the live path is `live_tap.sh`.
* **Verification**: full dialog `407 → 100 → 180 → 200 OK → ACK → RTP ↔ → BYE → 200`; caller sent 297 packets, UAS answered with 248, UAS received 47 520 RTP payload bytes (297×160 exactly); `rtpengine_packets_total` 0 → 594, `rtpengine_bytes_total` 0 → 102 168; pcap recorded per call; pcap→wav (10.9 s) → Vosk archived `{"text": ""}` (tone, no speech — correct) proving the whole record→transcribe→archive chain on a *real* call.
* **Note**: Vosk accuracy on real speech was already proven via mic recordings (`state/spool/archived/count_test.txt` → "the one two three four five six seven eight either"). `debug=1` suppresses `L_INFO` xlogs — the INTERCEPT QUERY/RESPONSE lines are invisible in production logs by design; keep `debug=2+` only for routing diagnostics.

### Issue 8.28: baresip `-d` Daemonize Kills REGISTER — Registration Goes Silently Unanswered

* **Symptom**: `baresip -d -f <cfgdir>` (daemonize) starts cleanly but the UA never receives any response to REGISTER — no 401, no 200 — while the same config backgrounded *without* `-d` registers normally (`401 → 200 OK` pair per REGISTER).
* **Root Cause**: a baresip quirk: in daemonize mode the main loop detaches before the SIP event loop is fully wired, so inbound responses are never dispatched. Only visible as silence in `-T` (trace) logs.
* **Fix**: never use `-d`. Run backgrounded as `baresip -f <cfg> -s -T` (containerized or with `setsid … &`); `-s` disables SIGINT handling, `-T` keeps the trace.
* **Verification**: both `baresip-rx`/`baresip-tx` containers (ubuntu:24.04, `mvno_mvno_net`) registered 2× `200 OK` each; digest REGISTER dialog proven live 2026-08-06.

### Issue 8.29: baresip ctrl_tcp Console — Netstring JSON Dialing (Port 4444)

* **Symptom**: piping commands to baresip's stdin fails (`fd_listen err: fd=0 (Operation not permitted)` — the stdio console cannot take a closed/EOF stdin) and `-e "dial …"` on the CLI is unreliable; `{"command":"dial","uri":"sip:…"}` over the TCP console returns `can't find a URI to dial to`.
* **Root Cause**: baresip's `ctrl_tcp.so` console (bound to `127.0.0.1:4444` inside the container) speaks **netstring framing** (`<len>:<json>,`) and the JSON key for the dial target is **`params`**, not `uri`; the `dial` command itself comes from `menu.so`, and `account.so`/`menu.so`/`ctrl_tcp.so` are **application modules** (`module_app`) — a plain `module` line silently skips them.
* **Fix**: load `module_app account.so`, `module_app menu.so`, `module_app ctrl_tcp.so`; dial with `MSG='{"command":"dial","params":"sip:15559998888@10.89.0.23:5060"}'; podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; printf '${#MSG}:${MSG},' >&3; timeout 2 cat <&3"` (host shell expands `${#MSG}` into the netstring length); hangup with `{"command":"hangup"}`.
* **Verification**: `CALL_OUTGOING`/`CALL_CLOSED` events + full 407→100→180→200→ACK→RTP→BYE dialog on the live baresip pair (2026-08-06).

### Issue 8.30: baresip Requires glibc ≥ 2.38 — Debian Bookworm Too Old

* **Symptom**: running the Arch-built baresip 4.6.0 binary in a Debian-based container fails at load: `version 'GLIBC_2.38' not found` (bookworm ships glibc 2.36).
* **Root Cause**: the host's baresip is linked against the host glibc; containers must provide ≥ 2.38.
* **Fix**: run in `docker.io/library/ubuntu:24.04` (glibc 2.39), with read-only mounts of `/usr/bin/baresip`, its 9 shared libs (`libbaresip.so.26`, `libre.so.41`, `libbrotli{common,dec,enc}.so.1`, `libcrypto.so.3`, `libssl.so.3`, `libz.so.1`, `libzstd.so.1`) and `/usr/lib/baresip` modules.
* **Verification**: both baresip containers on `mvno_mvno_net` (10.89.0.60/.61) registered and completed RTP calls; speech WAV (`aufile`) streamed both directions (2026-08-06).

### Issue 8.31: 2G MS-2 (15557778888) Is HLR-Only — No Handset, `sms.txt` Never Shows It

* **Symptom**: an SMS addressed to `15557778888` is accepted by OsmoSMSC (`Going to send a MT SMS` in the log) but never appears in `mvno-2g-ms:/root/.osmocom/bb/sms.txt`.
* **Root Cause**: the `mvno-2g-ms` container runs **one** `mobile` app (pid 1, `mobile -c /etc/osmocom/mobile.cfg`) serving only **MS1** (`IMSI 001010000000004` / `15554443322`). MS-2 exists in the HLR as subscriber 5 but has no handset in this test rig.
* **Fix**: always use `15554443322` (MS1) as the 2G recipient for any receipt check; `15557778888` remains valid only as a sender/HLR entity.
* **Verification**: raw SMPP 2G→2G and 5G→2G digest flows delivered to MS1 (`sms.txt` shows `[SMS from +15557778888]` / `[SMS from +15553332211]`), while a `15557778888`-recipient test stayed invisible (2026-08-06).

### Issue 8.32: Raw SMPP PDU Byte-Alignment — One Wrong Digit Corrupts the Whole SUBMIT_SM

* **Symptom**: hand-built `nc` SMPP BIND_TRANSCEIVER succeeds (status 0) but SUBMIT_SM gets **no response**; the SMSC log shows `smpp34_unpack()` error `[destination_addr:155544433322(OK)][tag:000E(OK)][length:4865(OK)][leng value.octet:18533(Value length exceed buffer length)]`.
* **Root Cause**: a 12-digit recipient (one extra `3`) and/or extra zero bytes before `sm_length` shift the whole PDU tail — OsmoSMSC's strict TLV unpacker then misreads the message bytes as TLV and drops the PDU without replying. The SMSC parses strictly; there is no lenient mode.
* **Fix**: build the PDU programmatically and verify byte-for-byte before use — the certified raw command is in the manual guide Section 0.6a (header `00 00 00 45 | 00 00 00 04 | 00 00 00 00 | 00 00 00 02`, then `00 01 01 <src 11 digits> 00 01 01 <dst 11 digits>`, eight `00` fields, `0e`, 14-byte body; total 69 bytes).
* **Verification**: exact-69-byte PDU → `Rx SUBMIT-SM (15554443322/1/1)` + `SMPP SUBMIT-SM: Stored in DB` + MS1 receipt; the corrupted variant produced the unpack error above (2026-08-06).

### Issue 8.33: `nc -u` Never Exits After the SIP Response

* **Symptom**: `printf 'MESSAGE …' | nc -u localhost 5060` prints Kamailio's 407/200 response but **hangs** — the command never returns and the shell blocks.
* **Root Cause**: the UDP socket stays open waiting for more input after the response; this nc build (openbsd-netcat) keeps reading until stdin EOF *and* does not self-close on a datagram reply.
* **Fix**: always wrap in `timeout 5 nc -u localhost 5060 < request.txt` (and feed the request from a file, not a live terminal).
* **Verification**: the digest flows (5G→2G, 5G→5G, E2E-BLOCK) complete with `SIP/2.0 200 OK` / `403` under `timeout` (2026-08-06).

### Issue 8.34: zsh `:ro` Volume-Mount Modifier + Non-Word-Splitting Breaks Mount Loops

* **Symptom**: `B="$B -v $f:$f:ro"` inside a `for f in …` loop silently corrupts mounts — podman errors `incorrect volume format` and the string shows `/usr/lib/libz.so.1:/usr/lib/libz.soo` (the `:ro` suffix mangled); a plain `$B` variable also fails even with correct contents.
* **Root Cause**: two zsh behaviors: (1) unquoted/plain `$f:ro` triggers zsh's **`:r` rootname modifier** (strips the last suffix, leaving `…so` + `o`); (2) zsh does **not** word-split unquoted variables (bash would), so the whole mount list arrives as one argument.
* **Fix**: use a zsh-safe array — `B=(-v /usr/bin/baresip:/usr/bin/baresip:ro); B+=(-v "${f}:${f}:ro"); …` then `podman run … "${B[@]}"`. Braces are mandatory around `${f}` before the `:ro` suffix.
* **Verification**: `"${B[@]}"` form runs both baresip containers with 11 clean `src:dst:ro` mounts; containers registered and called (2026-08-06). Documented in the manual guide Section 0 step 3.

### Issue 8.35: deploy.sh Offline Check Tests Nonexistent `vendor/images` Directory

* **Symptom**: `./scripts/deploy.sh --offline` always warned `vendor/images absent — cannot continue offline` and fell back to `BUILD=1` (source build) even when vendored image tarballs were present and loadable.
* **Root Cause**: `scripts/deploy.sh` (offline branch, ~line 112) tested `[ -d vendor/images ]`, but `scripts/bootstrap.sh` vendors tarballs under **`vendor/docker/`** (as documented in `docs/ENVIRONMENT_MATRIX.md` Section 4 and as consumed by `scripts/load-offline.sh`, which already checks `vendor/docker/`). The stale path made the check always false — silent degradation to source build, no error.
* **Fix**: both `scripts/deploy.sh` occurrences changed to `vendor/docker` (directory test + warning message).
* **Verification**: `bash -n scripts/deploy.sh` passes; with tarballs present in `vendor/docker/`, the offline branch now enters `load-offline.sh` instead of the build fallback. No image path referenced by the rest of the toolchain is named `vendor/images`.

### Issue 8.36: baresip pulse.so Loads Host-Glibc-2.44 Libs into a glibc-2.39 Container — Host Dynamic Loader Required

* **Symptom**: with the Step 3 mount list extended by the full `ldd` closure of `pulse.so`, baresip fails at startup: `dl: mod: /usr/lib/baresip/modules/pulse.so (/lib/x86_64-linux-gnu/libm.so.6: version GLIBC_2.43 not found (required by /lib/libmp3lame.so.0))` — module load aborts, `ausrc: pulse` never initializes. A second symptom: mounting the host loader at a **usrmerge path** (`/usr/lib64/ld-linux-x86-64.so.2`) hijacks every exec'd binary — `podman exec baresip-tx bash` dies with `undefined symbol: __nptl_change_stack_perm, version GLIBC_PRIVATE` (the container's bash 2.39 runs under the host 2.44 loader which demands a 2.44-private libc symbol).
* **Root Cause**: the host is glibc **2.44**; `libmp3lame.so.0`/`libmpg123`/`libsndfile`/`libFLAC` etc. in the pulse closure were built against ≥ 2.43 and cannot load in `ubuntu:24.04` (glibc 2.39). The baresip binary itself is host-built, so the container's loader is the wrong interpreter for the whole closure.
* **Fix**: run baresip under the **host dynamic loader**, mounted at a non-usrmerge path: `-v /usr/lib64/ld-linux-x86-64.so.2:/hostld/ld-linux-x86-64.so.2:ro`, invoked as `/hostld/ld-linux-x86-64.so.2 --library-path /usr/lib:/usr/lib/pulseaudio /usr/bin/baresip …`. `--library-path` also covers `libpulsecommon-17.0.so` (only in `/usr/lib/pulseaudio/`), so no `LD_LIBRARY_PATH` env is needed.
* **Verification**: inside the container, `--list` on `baresip` and `pulse.so` shows zero `not found`; logs show `pulse: initialized (Success [0])` + `ausrc: pulse`; `podman exec` bash stays healthy; live-mic call transcribed the spoken phrase and produced the expected spam verdict (2026-08-06).

### Issue 8.37: Stale Demo SIP Registrations Mask the IP-SM-GW Bounded-Retry Flow (O.2)

* **Symptom**: manual guide Flow O.2 ("deliver_attempts climbs to 5, then the row leaves the pending set") is unreproducible: every injected 2G→5G row to `15559998888` logs `[SEND] … OK` / `[DELIVERED]` immediately and `deliver_attempts` never leaves 1 — despite the 5G recipient appearing unregistered (no UE maps to that MSISDN; Open5GS subscribers only carry 15551234567/15557654321/15550000000).
* **Root Cause**: live_demo.sh's SIP traffic simulators leave **live registrations behind in Kamailio's usrloc** after the containers are removed. `state/kamailio/kamailio.db` `location` table held 15559998888 contacts from: (a) demo item 5's `ims-uas58` (`sip:15559998888@10.89.0.58:5070`, `Expires: 3600`), (b) demo item 5b's `sip_traffic_sim.py --callee 15559998888` run from `mvno-ueransim-ue-1` (ephemeral-port contacts at 10.89.0.14, rewritten by `fix_nated_contact`), and (c) since the 5b rework (2026-08-06) the 5b **UAS** (`sip:15559998888@10.45.0.8:5070`), which persists in usrloc for its full 3600 s expiry even after the UAS process is killed. Kamailio's MESSAGE branch then `t_relay`s successfully (200 OK) instead of `404 Not Found`, so the bridge's `mark_attempt()` path never fires. Note also the 200 OK from a *real* 404-less flow initially misled diagnosis — `kamailio.cfg` runs `debug=1` (L_WARN only), so the L_INFO `INTERCEPT_SMS` xlogs are suppressed and the MESSAGE path is invisible in `podman logs mvno-kamailio`.
* **Fix**: before running O.2, clear the stale AoR with a digest-authenticated `REGISTER` carrying `Contact: *` + `Expires: 0` (any client; `testpass` digest over UDP 5060, proxy realm `localhost`). Verified live: response `SIP/2.0 200 OK`, subsequent authenticated `MESSAGE` to 15559998888 returns `SIP/2.0 404 Not Found`, and the retry climb works.
* **Verification**: injected `15554443322 → 15559998888`; bridge logged four `[RETRY] row_id=140 attempt counted` events; `smsc.db` row 140 `deliver_attempts` climbed 1→2→3→5 then left the pending set (no further POLLs) — bounded, no infinite spin (2026-08-06). Evidence: `docs/evidence/o2-bounded-retry.txt`. Re-verified 2026-08-06 after the 5b rework: the first attempt was masked again by the 5b UAS binding (row delivered on poll 1); after the `Contact: *` deregister → authenticated MESSAGE `404 Not Found`, row 147 climbed to `deliver_attempts=5` and went inert.

### Issue 8.38: init-db Non-Upsert Seed Lets Stale Subscriber Balance Survive Cold Cycles (Demo Item 6/13)

* **Symptom**: on a true cold-start cycle (2026-08-08), `live_demo.sh` item 6/13 failed: `[-] Error: Did not receive SIP 403 Forbidden for zero-balance call` — the 407 challenge succeeded but the digest-authenticated INVITE was not rejected with 403. Gateway reported `{"msisdn":"15557654321","balance":100}` even though the Makefile seed explicitly writes `VALUES (…,'15557654321', 0)`.
* **Root Cause**: two compounding facts. (1) `make init-db` seeded the kamailio subscriber table with `INSERT OR IGNORE` — a **non-upsert** statement that never corrects an already-existing row. The `subscriber` table persisted across many re-seeds (autoincrement ids 120–125), so the row for `15557654321` had a stale `balance=100` from an earlier seed that no later `INSERT OR IGNORE` could fix. (2) The live-balance correction made during the demo work (a host-side `UPDATE subscriber SET balance=0`) landed in the **SQLite WAL**, not the main DB file; the next cold `make init-db` (kamailio down) hit its WAL/shm cleanup guard (`rm -f kamailio.db-wal kamailio.db-shm` when kamailio is not running) and **discarded the uncheckpointed write**, reverting the row to the stale 100 in the main file. Net effect: the zero-balance contract (`15557654321` = blocked identity, per demo item 6/13 and `VERIFICATION_MODEL.md`) silently broke on every cold re-seed.
* **Fix**: convert the five kamailio subscriber seeds in `Makefile init-db` from `INSERT OR IGNORE` to true **UPSERTs**: `INSERT INTO subscriber (…) VALUES (…) ON CONFLICT(msisdn) DO UPDATE SET balance=excluded.balance`. `init-db` now enforces the canonical balances (UE1/3/4/5 = 100, UE2 = 0) on every run regardless of prior DB state or WAL deletion — idempotent by construction.
* **Verification**: after the fix, `make init-db` → `sqlite3 state/kamailio/kamailio.db 'SELECT username, balance FROM subscriber'` shows `15557654321|0` (only zero-balance row) and the gateway returns `{"msisdn":"15557654321","balance":0}`; `live_demo.sh` then passed **ALL 13 ITEMS (exit 0)** including item 6/13 (407 → digest → 403) on the cold-started stack; `make gate` SMS MATRIX 8/8 remained green. `provision-subscribers.sh` and `seed-mongo.sh` carry no balance field and do not override the SQLite value (verified by grep). Note: `provision-subscribers.sh` also upserts a parallel MongoDB `kamailio.subscriber` doc (no balance field) that the SQLite `auth_db` path does not read — a dual-track store, not a balance source; the SQLite `subscriber` table is authoritative for `telecom-api` balance lookups.

### Issue 8.39: Watchdog `--self-test` Recovery Path Was Never Exercised

* **Symptom**: the watchdog's committed 2-round bridge-restart recovery (`recover()` → `podman restart`, ≤2 attempts) was never executed, so the "not exercised" audit gap went unproven; a transient restart failure could previously log `ERROR` while the bridge's own retry loop silently recovered.
* **Root Cause**: no fault-injection path existed to prove recovery end-to-end.
* **Fix**: added `--self-test` mode — `podman stop mvno-ip-sm-gw`, assert the outage took, run one `recover()`, assert `/health` returns 200; safe because `recover()` calls `demo_running()` (lock files + `mvno-live` tmux + pgrep gate/sms_matrix/live_demo/demo_live) and skips when a demo is in flight.
* **Verification**: `bash scripts/mvno-stack-watchdog.sh --self-test` exits 0 and logs `self-test PASS: bridge outage recovered (restart -> /health 200)`; `make watchdog-self-test` tees to `docs/evidence/watchdog-recovery-<date>.log`.
* **Status**: X (resolved by abaa766)
* **Verified-by**: abaa766 — self-test exit-code propagation + live-watchdog race fix; `state/logs/watchdog.log` 2026-08-08 shows bridge restart round 2 → `/health` 200 after a real TERM-strand recovery.

### Issue 8.40: `cockpit_proof.sh` Stale-Evidence False-PASS Window (Proof Harness)

* **Symptom**: the proof's freshness baseline is a single `touch /tmp/cockpit-proof-$$.mark`; a pre-existing demo's already-written `state/spool/live-*.wav`, `state/spool/archived/*.txt`, or `state/spool/pcaps/*.pcap` with mtime ≥ the mark can satisfy the mid-call evidence assertion and green the proof on **stale** data.
* **Root Cause**: the mark only anchors "newer-than"; it does not clear pre-existing spool artifacts, so a healthy-but-not-fresh run can pass.
* **Fix**: after tearing down any pre-existing `mvno-live` session and before launch, `rm -f state/spool/live-*.wav state/spool/archived/live-*.txt state/spool/pcaps/*.pcap` (non-interactive mode only, preserving real recordings under `--live-mic`), then require evidence to appear; keep `-newer "$MARK"` as belt-and-suspenders.
* **Verification**: `make cockpit-proof` twice back-to-back — both must PASS, the second proving no stale file satisfies it.
* **Status**: X (resolved by b1cd9af)
* **Verified-by**: b1cd9af — audit false-PASS/false-FAIL risk closure in the proof harness; two consecutive `make proof` runs green.

### Issue 8.41: `subscriber_proof.sh` Hardcoded Throwaway MSISDN Races (Proof Harness, optional-hardening)

* **Symptom**: `THROWAWAY=15551234999` is hardcoded; parallel/concurrent `make proof` runs (or historical archives) can both purge/provision the same MSISDN and race, and an `add-subscriber.sh` die mid-provision (its documented "mongo step under set -e" half-provision guard) can leave a stray row.
* **Root Cause**: a fixed, non-unique throwaway plus no absence-assert after pre-purge.
* **Fix**: derive a time/random-unique MSISDN suffix at runtime; after pre-purge, assert the throwaway is **absent** from all 5 stores and fail (non-zero) if any row remains, so a leftover from an interrupted run stops the proof instead of proceeding to a probable `add-subscriber` die.
* **Verification**: two parallel/subsequent `make subscriber-proof` runs both PASS without an "exists" pre-purge failure; a deliberately left-over row makes the proof fail-fast.
* **Status**: X (resolved by b1cd9af)
* **Verified-by**: b1cd9af — time-unique throwaway MSISDN + post-purge absent-assert; `docs/evidence/demo-subscriber-2026-08-08.log` shows a clean provision/assert/teardown run.

### Issue 8.42: `subscriber_proof.sh` SIP-REGISTER String-Match Fragility (Proof Harness, optional low)

* **Symptom**: the UAS assertion greps the exact string `SIP REGISTER 200 OK for subscriber ${THROWAWAY}`; if `sip_traffic_sim.py`'s output format drifts (trailing colon, `SIP/2.0 200 OK` variant), the proof false-FAILs.
* **Fix** (optional): relax to a looser `REGISTER[^\n]*200 OK` match on the UAS output.
* **Verification**: `make subscriber-proof` still green.
* **Status**: X (resolved by b1cd9af)
* **Verified-by**: b1cd9af — UAS match relaxed to a looser `REGISTER[^\n]*200 OK`; `make subscriber-proof` green after the change.

### Issue 8.43: Caller Now Gets an Audible Call-Open Beep (Demo UX)

* **Symptom**: at call-open the live-mic speak-window was ambiguous — the operator had to watch the terminal for the `SPEAK NOW` countdown instead of hearing when to start talking.
* **Fix**: `play_go_beep()` in `scripts/lib/common.sh` generates a 0.48 s 660→880 Hz two-tone once into `${TMPDIR}` via ffmpeg and plays it via `paplay` (Pulse socket) → `aplay` → terminal BEL; fired from `demo_call.sh dial()` at the start of the SPEAK NOW window (and the tone-fallback TALK NOW branch) and from `mic_record.sh` before capture; `MVNO_NO_BEEP=1` mutes for headless runs and the deterministic proofs stay tone-caller-based.
* **Verification**: with a Pulse socket, `demo_call.sh dial` beeps at the start of the speak-window and the user's speech lands in the near-real-time Vosk path; `MVNO_NO_BEEP=1 make cockpit-proof` twice — both green.
* **Status**: X (resolved by ec30a12)
* **Verified-by**: ec30a12 — audible go-cue shipped (feature, not a fault); `MVNO_NO_BEEP=1` proof runs stay deterministic.

> **Audited-and-clear**: two suspected issues were investigated and refuted —
> full reasoning moved to **§11 Not-Issues** (quarantine) so they are not re-filed as bugs.

### Issue 8.44: True-Cold HLR Crash-Loop — init-db minimal schema vs osmo-hlr v7 (2G leg down)
* Symptom: on a truly cold start (`make clean` -> `make bootstrap`) `mvno-osmo-hlr`
  crash-loops `Exited (1)` with `Error opening database` and the 2G leg is dead;
  `make gate` fails at preflight. Warm-state runs never hit it (the pre-existing
  full-schema hlr.db masked the defect).
* Root Cause: init-db created a minimal `subscriber (id, imsi, msisdn)` table.
  osmo-hlr 1.9.3 (`--db-upgrade`) reads `PRAGMA user_version` (NOT a meta table)
  and expects the full **v7** schema. The minimal table reads as user_version 0,
  so the v1->v7 upgrade path runs and fails twice: first `no such column:
  imeisv` in the v3 `subscriber_backup` copy, then (after a partial column fix)
  `NOT NULL constraint failed: subscriber_backup.nam_cs` — leaving the DB at
  user_version 2 with a half-mutated table, crash-looping on every retry.
* Fix: init-db now creates the exact v7 schema from osmo-hlr `sql/hlr.sql`
  (subscriber with `msc_number` — `hlr_number` was renamed in v3 — and
  `nam_cs`/`nam_ps`/`ms_purged_cs`/`ms_purged_ps` NOT NULL DEFAULTs, plus
  `subscriber_apn`/`subscriber_multi_msisdn`/`auc_2g`/`auc_3g`/`ind` and
  `PRAGMA user_version = 7`), with a drop-if-broken guard that rebuilds the
  schema only when `msc_number` is missing AND `mvno-osmo-hlr` is not running
  (WAL-shared with the live process otherwise).
* Verification: osmo-hlr Up (healthy) logging `schema version 7`, telnet/CTRL/
  IPA interfaces up, osmo-msc connected; `make gate` 8/8 and `make proof` 3/3
  PASS on the cold state (fresh evidence in `docs/evidence/e2e-run-*`,
  `demo-cockpit-*`, `demo-subscriber-*`, `watchdog-recovery-*`).
* Status: X (resolved by d23f43c)
* Verified-by: d23f43c — init-db writes the exact osmo-hlr v7 schema with a
  drop-if-broken guard; full cold wipe (`make clean` → `make bootstrap`) green.

### Issue 8.45: Cold-Start Ordering Gaps in Docs & Setup (make up alone is not enough)
* Symptom: LIVE_DEMO S1 and ONBOARDING said `make up` only; on a fresh box the
  subscriber DBs and Open5GS Mongo were never created, so SMS auth / balance-403
  / HLR lookups and 5G UE registration would all fail. `deploy.sh` (the
  documented one-command path) also ran `init-db` but never `seed-mongo`.
* Root Cause: `make up` / `up.sh` is a pure compose launch; the DB init and
  Mongo seed are separate steps, and `seed-mongo.sh` must run AFTER `up` (it
  execs into the running mongodb container). The order was undocumented.
* Fix: `make bootstrap` = `init-db -> up -> seed-mongo` (one-command cold
  start); `deploy.sh` gained the missing `seed-mongo` step; LIVE_DEMO S1,
  README, ONBOARDING, deployment_guide, ENVIRONMENT_MATRIX and
  TESTING_REFERENCE all state the canonical order. `seed-mongo.sh` now also
  polls mongodb readiness (bounded 60s) so a cold bootstrap cannot race
  mongod's boot.
* Verification: the documented sequence was executed live end-to-end on a
  wiped state (`make clean` -> `init-db` -> `up` -> `seed-mongo`) with `make
  gate` 8/8 and `make proof` 3/3 green.
* Status: X (resolved by 9239dc5, refined 5393b61)
* Verified-by: 9239dc5 (make bootstrap + deploy.sh seed-mongo) and 5393b61
  (seed-mongo mongodb-readiness poll + README/ONBOARDING order); cold-state
  verification committed with the gate/proof evidence logs.

### Issue 8.46: Host UFW Drops Cross-LAN SIP Media — misdiagnosed as "rootlessport/Podman cross-LAN UDP" (phone RTP never reaches rtpengine)
* Symptom: a real Android phone (Linphone) registered to Kamailio over SIP
  5060 (works — UFW allows 5060) and placed a call, but no voice reached the
  rig: rtpengine_packets_total stayed ~0, recording pcap empty/RTCP-only, no
  wav, Vosk returned `{'text':''}` (or empty). Every attempt to fix it in the
  *container* layer failed, because the real cause was never in Podman.
* Root Cause: the **host UFW firewall** (`/etc/ufw/user.rules`,
  `DEFAULT_INPUT_POLICY="DROP"`) silently drops inbound UDP/TCP from LAN
  clients on every port except the allow-list:
  `22/tcp`, `5038/tcp`, `4573/tcp`, `5070/tcp+udp`,
  `udp 10000:20000`, and `udp 10000:10010`. rtpengine was configured for
  `port-min=30000, port-max=30100`, which falls **outside** the UFW-allowlist
  → `[UFW BLOCK]`. Evidence (irrefutable, in the kernel journal):
  ```
  kernel: [UFW BLOCK] IN=wlan0 ... SRC=192.168.100.232 DST=192.168.100.93
          ... PROTO=UDP DPT=30054 / DPT=30040 / DPT=30150 ...
  kernel: [UFW BLOCK] ... PROTO=TCP DPT=55770 (SYN)
  ```
  The packets ARRIVE at the host wlan0 (tshark sees them; the UFW BLOCK log is
  emitted at the netfilter hook) but are dropped in the `input` chain before
  any userspace socket — a **plain host `socat`/python UDP listener bound to
  `0.0.0.0:P` or `192.168.100.93:P` gets nothing**, and therefore neither does
  rootlessport/pasta/rtpengine. This is why the earlier "rootlessport drops
  cross-LAN UDP" conclusion was a **misdiagnosis**: rootlessport and pasta BOTH
  forward host-sourced UDP fine, and BOTH correctly forward phone UDP **once
  the port is UFW-allowled**. Positive control: phone UDP to UFW-allowled port
  5070 arrives at a host socket AND, via the published 10000-20000 range,
  arrives inside the rtpengine container (`CONTAINER-GOT:` from 10.89.0.48).
* Fix: align rtpengine's media range with the UFW-allowlisted industry-standard
  SIP RTP window so external clients are plug-and-play — register on 5060, send
  RTP on 10000-20000:
  - `configs/rtpengine/rtpengine.conf`: `port-min=10000`, `port-max=20000`.
  - `docker-compose.yml`: publish `10000-20000:10000-20000/udp` (was
    `10000-20000:10000-20000/udp`).
  - `scripts/demo/demo_live.sh`, `scripts/testing/cockpit_proof.sh`:
    tshark/wireshark RTP decode filters `portrange 10000-20000` →
    `10000-20000`.
  - `configs/grafana/provisioning/alerting/rules.yml`: RTP-free-port alert
    `port-min=30000` → `port-min=10000` wording.
  (No firewall/sudo change was needed — the 10000-20000 window is already
  the UFW-default VoIP allow. If a deployment uses a different media range,
  the SOTA fix is one `sudo ufw allow 30000:30100/udp` — see docs section.)
* Verification: `podman compose up -d rtpengine` → rtpengine publishes
  10000-20000; `ss -lun` shows the range bound; phone UDP to a published port
  (e.g. 10020) reaches a socket inside the container; no `[UFW BLOCK]` on the
  new range; positive control on UFW-allowled 5070 delivers. The internal
  baresip-rx/baresip-tx rig (both on mvno_net, no published ports) is
  unaffected and continues to record/transcribe on the new range.
* Status: X (resolved by e6a361a)
* Verified-by: e6a361a — media range aligned to the UFW-allowlisted 10000-20000
  window; cross-LAN phone UDP now reaches the rtpengine container end-to-end.
* Distinct-from: 8.20 (rootless-podman has no host route to container IPs) —
  different layer: 8.20 is a routing/SNAT problem inside the bridge net;
  8.46 is a host firewall (UFW) input-chain drop of LAN media before any
  userspace socket, diagnosed via kernel [UFW BLOCK] logs.
* Distinct-from: 8.27 (IMS voice INVITE never reaches callee) — different
  symptom: 8.27 is SIP signaling not completing to the callee; 8.46 is the
  phone's RTP media being firewall-dropped after a successful INVITE.
* Distinct-from: 8.33 (nc -u never exits) — different issue: 8.33 is a test
  tooling quirk (nc -u not sending EOS); 8.46 is a production firewall gap.
* Best-practices note (industry-standard SIP/UDP mapping):
  SIP signaling `5060/udp+tcp`, RTP media on one contiguous even/odd
  even=audio/odd=RTCP window within `10000-20000`, 1:1 host→container port
  mapping (no range translation), media-proxy SDP advertising a *reachable*
  address (`interface=eth0!192.168.100.93` — not the private bridge
  10.89.0.48). Any range is fine as long as it sits inside the host firewall
  allow-window; pick the documented 10000-20000 so zero firewall changes are
  needed for external SIP clients.

### Issue 8.47: baresip `pulse` ausrc never captures — falls back to `ausine` (440 Hz tone) at call time (laptop-mic blocker)
* Symptom: baresip-tx (the caller leg, `15553332211@10.89.0.23:5060`, container
  on `mvno_mvno_net` at 10.89.0.61) is configured `audio_source pulse` and the
  `pulse.so` module logs `pulse: initialized (Success [0])`, `ausrc: pulse`,
  `auplay: pulse` at module load — yet at **call time** the TX pipeline runs
  `ausine ---> aubuf ---> PCMU` (a mechanical 440 Hz tone, `ausine: ... frequency
  440 Hz`), so the laptop hardware mic is **never** captured on the caller leg.
* Root Cause (REVISED 2026-08-13 — the original inference was WRONG): baresip's
  `pulse` capture DOES work in this rootless-Podman rig when the container is
  launched with the correct recipe. The original "never records" conclusion was
  based on a **flawed `parec`-based test** that (a) omitted the `PULSE_SERVER`
  and `XDG_RUNTIME_DIR` env vars and (b) ran as uid 1000. Empirically re-verified
  this session:
  - A **fresh** container (uid 0, `--security-opt label=disable`, host pulse
    socket `/run/user/1000/pulse/native` + cookie mounted, env
    `PULSE_SERVER=unix:/run/user/1000/pulse/native` +
    `XDG_RUNTIME_DIR=/run/user/1000`) running baresip's `pulse.so` module opens a
    real record stream: `pactl list source-outputs` shows a baresip source-output
    (`s16le 1ch 8000Hz`) bound to source 514 =
    `alsa_input.pci-0000_05_00.6.analog-stereo` (the real laptop HW mic), and a
    matching sink-input on sink 513 = the laptop speakers. No file, no aufile,
    no feeder — genuine real-time full-duplex capture.
  - The scratch `parec` used in the original RCA is **not a valid probe**: even
    with the working recipe, a fresh-container `parec` returns 0 bytes, while
    baresip's own `pulse.so` succeeds. The RCA's parec numbers (64000 B vs
    120 B) therefore do not reflect baresip's behavior.
  - The working recipe is reproducible in a fresh container (not a fluke of a
    long-running process).
* Fix: run the baresip container on the bridge
  net as **root (uid 0)** with `--security-opt label=disable`, mount the host
  pulse socket + cookie, set `PULSE_SERVER=unix:/run/user/1000/pulse/native` and
  `XDG_RUNTIME_DIR=/run/user/1000`, and configure
  `audio_source pulse,alsa_input.pci-0000_05_00.6.analog-stereo` +
  `audio_player pulse,alsa_output.pci-0000_05_00.6.analog-stereo`. The `aufile`
  WAV workaround is no longer needed for live laptop-mic capture.
* Verification: a fresh container (uid 0, label=disable, host pulse socket +
  cookie, PULSE_SERVER/XDG_RUNTIME_DIR set) shows `pactl list source-outputs`
  with a baresip source-output (s16le 1ch 8000Hz) bound to source 514 = the
  real laptop HW mic during an internal call; the TX pipeline runs the pulse
  source, not the ausine tone fallback.
* Status: X (fixed — real-time live laptop-mic capture via baresip `pulse` in a
  rootless-Podman container is proven; the remaining open item is the separate
  Android-Linphone NAT/reachability issue, tracked separately).
* Verified-by: `pactl list source-outputs`/`sink-inputs` showing baresip
  (client `application.name=baresip`) bound to source 514 / sink 513 during an
  internal call; fresh-container reproduction (source-output 3353 → 514).
* Distinct-from: 8.36 (glibc ABI load) — different root cause: 8.36 is a host
  dynamic-loader/glibc mismatch at module load; 8.47 is pulse ausrc never
  capturing at call time despite pulse.so loading fine.
* Distinct-from: 8.27 (IMS voice INVITE never reaches callee) — different
  issue: 8.27 is SIP signaling/media-plane delivery; 8.47 is the caller-leg
  audio source (pulse ausrc) inside baresip-tx falling back to a tone.

### Issue 8.48: callee `answermode=auto` alone does not auto-answer (add `sip_autoanswer=yes`)
* Symptom: baresip-rx (`15559998888@10.89.0.23:5060`, the callee streaming the
  scam phrase from `/media/speech8k.wav`) with account line
  `...;answermode=auto` accepted incoming INVITE (logs `menu: ... Incoming
  call ...`) but stayed at `180 Ringing` and never sent `200 OK`.
* Root Cause: `answermode=auto` only enables auto-accept in the `menu`/`call`
  layer when the account is registered and the `sip_autoanswer` account option
  is also set; without `sip_autoanswer=yes` baresip answers the INVITE with
  `180 Ringing` and waits for a human (or another auto-answer mechanism) to
  accept.
* Fix: add `sip_autoanswer=yes` (and `answerdelay=0`) to the rx account line so
  the `menu`/`account` module actually answers. After the change the incoming
  call completes (`Call answered`, `Call established`, `RTPESTAB`).
* Verification: with `sip_autoanswer=yes` on the rx account, an inbound INVITE
  completes with `200 OK`/`Call established`/`RTPESTAB` in baresip-rx logs
  (was `180 Ringing` only).
* Status: X (fixed in this session's `state/baresip/rx/accounts`).
  NOTE: `state/baresip/rx/accounts` is a generated artifact (demo_call.sh writes
  it with `answermode=auto`); upstream demo scripts should also emit
  `sip_autoanswer=yes` to keep auto-answer reliable.

### Issue 8.49: label_transcript.sh caller pattern `*55332211*` never matched 15553332211
* Symptom: `scripts/testing/label_transcript.sh` side-labeled the callee
   correctly (`*559998888*` → `[CALLEE (15559998888)]`) but reported the caller
   leg as `[UNKNOWN]` even though the caller's RTCP SDES CNAME
   (`sip:15553332211@10.89.0.23:5060`) was present.
* Root Cause: the caller MSISDN is **15553332211** — digits
   `1-5-5-5-3-3-3-2-2-1-1` (three 5s and three 3s) — so the literal glob
   `*55332211*` (two 5s/two 3s) is **not** a substring and never matched.
* Fix: match the unique stable tail `*3332211*`:
   `*3332211*) side="CALLER (15553332211)" ;;`.
* Verification: after the change the same pcap labels
   `[CALLER (15553332211) | rtp-port 10570]` correctly.
* Status: X (fixed in the working tree; safe to commit).

### Issue 8.50: Android Linphone INVITEs loop back to Kamailio — rootlessport destroys the phone's source IP (self-loop contact `10.89.0.23:port`)
* Symptom: the phone registers through the host port-map
  (`192.168.100.93:5060 → kamailio:5060`) and the REGISTER succeeds, but
  `fix_nated_contact()` stores a **self-loop contact** (`sip:15551234567@10.89.0.23:port`,
  Kamailio's own bridge IP) in the location table, so INVITEs to the phone loop
  back into Kamailio and never reach the device — the phone never rings.
* Root Cause: the rootless bridge container was created **before**
  `rootless_port_forwarder="pasta"` was set in `~/.config/containers/containers.conf`
  (2026-08-11 23:59:40); the container still used the legacy `rootlessport`
  userspace proxy, which rewrites the source IP of inbound LAN UDP to the bridge
  gateway/NAT address. Kamailio therefore sees the phone's REGISTER arriving
  from its own bridge IP and `fix_nated_contact()` mints a self-loop contact.
  `save("location","0x04")` is NOT a fix (0x04 = contact dedup, not
  received-address); `received_avp` would also record the NAT'd address.
* Fix (industry-standard, Podman 6.0 PR #28478): keep Kamailio on the bridge
  (mvno_net DNS to `rtpengine`/`mvno-api` intact) and switch rootless bridge
  port forwarding from `rootlessport` to **pasta**, which preserves the real
  client source IP:
  - `~/.config/containers/containers.conf` `[network]`:
    `rootless_port_forwarder = "pasta"` (already present; requires
    `passt >= 0:20260526.g038c51e`; this rig has `2026_07_28.f8df3f1`).
  - **Recreate** the container so the forwarder is picked up at creation time
    (`podman compose up -d --force-recreate kamailio`). First kill the stale
    `passt.avx2`/`rootlessport` processes holding the old port
    (`kill <pid>`; `ss -ulpn | grep 5060` to confirm the fresh `passt.avx2`
    owns it).
  - Verify: `podman info` shows `RootlessNetworkCmd: pasta`; the phone's
    re-REGISTER lands in the location table as its REAL address
    (`sip:15551234567@192.168.100.31:port;transport=udp`), not a self-loop.
* Verification (2026-08-13, live): baresip-tx dialed `15551234567`; the phone's
  Linphone (adb dc76f546) answered — `CallActivity` foreground on the device,
  `AudioPlaybackConfiguration ... USAGE_VOICE_COMMUNICATION` active, baresip-tx
  reported `ESTABLISHED`, and rtpengine recorded **both** legs with real Vosk
  transcripts (leg 11344: "hello hello hello", "conference calls"; leg 11358:
  "hello hello", "are you calling from from poem or"). End-to-end live Android
  call through the full pipeline proven.
* Status: X (resolved 2026-08-13 — recreate container after pasta config)
* Best-practices note: the port forwarder is chosen at container **creation**
  time — changing `containers.conf` alone does not affect already-created
  containers. `--network host` and macvlan were ruled out (host has no route to
  10.89.0.0/24; rootless macvlan cannot reach the LAN).
* Distinct-from: 8.22 (IP-SM-GW bridge tight recv loop) — different issue:
  8.22 is the 2G/5G SMS bridge's socket read loop tripping Kamailio pike;
  8.50 is the Android phone's SIP REGISTER source-IP being rewritten by
  rootlessport so INVITEs self-loop in Kamailio.
* Distinct-from: 8.46 (host UFW drops cross-LAN media) — different layer:
  8.46 is a firewall input drop of RTP before userspace; 8.50 is a port
  forwarder (rootlessport vs pasta) rewriting the phone's source IP so
  fix_nated_contact() mints a self-loop — both phone-reachability, but
  disjoint mechanisms and disjoint fixes.

### Issue 8.51: IP-SM-GW bridge silently dropped every Linphone-originated SMS — strict `To: <sip:` regex vs RFC 3261 bracketless form (5G→2G Cell 3)
* Symptom: Android Linphone messages (and any client sending `To: sip:...@...`
  WITHOUT angle brackets) were 407-challenged, re-sent authorized, then got NO
  response — Kamailio relayed to the bridge but the bridge never replied;
  after ~30 s Kamailio's tm timer sent 408 and the phone showed the message as
  undelivered. Scripted senders (`ims_terminal.py`, which sends `To: <sip:..>`
  WITH brackets) worked — which hid the bug.
* Root Cause: `parse_sip_message()` used `To:\s*<sip:(\d+)@` — the `<` was
  REQUIRED. RFC 3261 permits both forms; Linphone sends the bare form
  (`To: sip:15554443322@localhost`). recipient resolved to `None` →
  `recipient in MSISDN_2G` was False → `handle_inbound` returned SILENTLY (no
  RELAY log, no 200).
* Fix: make the `<` optional in both From and To regexes
  (`From:\s*<?sip:` / `To:\s*<?sip:`), regression tests added
  (`test_linphone_bracketless_to_and_from`).
* Verification: live 2026-08-14 — `DIAGPHONE4-FIXED` from the phone relayed +
  SMPP-submitted + landed in the 2G MS `sms.txt`, and the full sms_matrix
  Cell 3 (5G→2G) went green.
* Status: X (fixed 2026-08-14, `scripts/ip_sm_gw.py`; suite now 33/33)
* Verified-by: live phone→2G delivery 2026-08-14 + sms_matrix Cell 3 green
* Lesson: the scripted-only test path (all senders emit `<sip:..>`) masked a
  real-client format divergence. Add the real phone as a matrix sender.
* Distinct-from: 8.24 (AI-Filter mock chunked body) — different layer: 8.24 is
  the API-side mock reading an empty body; 8.51 is the bridge's SIP header
  parser rejecting a legal RFC 3261 bracketless form.
* Distinct-from: 8.26 (bridge registrations die silently) — different defect:
  8.26 is the bridge's REGISTER refresh (fixed Call-ID/CSeq) dying after hours;
  8.51 is a per-message parse drop of bracketless From/To headers.
* Distinct-from: 8.52 (typing indicators relayed) — different message class:
  8.52 is RFC 3994 is-composing MESSAGEs being relayed; 8.51 is real SMS text
  dropped because of a header-format parse miss.

### Issue 8.52: Linphone RFC 3994 typing indicators relayed to the 2G MS as literal SMS
* Symptom: while typing, the phone emits `MESSAGE` with
  `Content-Type: application/im-iscomposing+xml`; the bridge relayed the raw
  XML body to OsmoSMSC and the 2G MS displayed/stored it as an SMS
  (`sms.txt` showed the raw `<isComposing><state>active</state>` XML).
* Root Cause: no content-type gate anywhere — the bridge treated every relayed
  MESSAGE as SMS and forwarded the XML body; Kamailio also passed it through to
  the intercept API, polluting the SMS record store with fake "typing SMS".
* Fix: two gates — (a) `is_typing_indicator()` in the bridge
  (`scripts/ip_sm_gw.py`): is-composing content type is ACKed to Kamailio (so
  the sender's delivery state stays clean) but never relayed to 2G, and
  (b) a Kamailio `route[INTERCEPT_SMS]` gate (`$hdr(Content-Type) =~
  "iscomposing"` → silent 200, no API call, no relay) so ANY client's typing
  indicators are consumed before the intercept API or the bridge ever see them
  — one gate covers every client, no reliance on client-specific body quirks.
  Tests added.
* Verification: live 2026-08-14 — `[SKIP] typing indicator` logged in the
  bridge, `SMS TYPING-INDICATOR CONSUMED (im-iscomposing)` in Kamailio, only
  the real text reached sms.txt, and no fake SMS row hit the API.
* Status: X (fixed 2026-08-14)
* Verified-by: live phone-typing run 2026-08-14 (both gates in the log)
* Distinct-from: 8.51 (bracketless To drop) — different message class: 8.51
  drops real SMS text on a parse miss; 8.52 relays non-SMS (typing) MESSAGEs
  as SMS. Both are bridge 5G→2G defects, disjoint fixes.

### Issue 8.53: Kamailio `debug=1` suppresses the `SMS INTERCEPT` L_INFO xlogs that prove the routing path
* Symptom: during diagnosis, `podman logs mvno-kamailio` showed only the
  jansson ERROR lines, never the `SMS INTERCEPT QUERY/PAYLOAD/RESPONSE` xlogs,
  so it was impossible to see where the phone's message went.
* Root Cause: `debug=1` (config line 15) prints only levels ≤ L_ERR;
  `xlog("L_INFO")` needs a higher threshold. The config comment claims L_INFO
  xlogs are "preserved" — they are not.
* Fix: raise to `debug=3` (L_WARN + L_INFO-adjacent, no q_malloc spam) only
  while diagnosing; revert to `debug=1` after. Consider a permanent `debug=3`
  so intercept events stay visible without memory-allocator noise.
* Verification: with `debug=3`, `podman logs mvno-kamailio` shows the
  `SMS INTERCEPT QUERY/PAYLOAD/RESPONSE` xlogs during a live message;
  with `debug=1` they are absent (observed 2026-08-14).
* Status: AO (audited-only observation, 2026-08-14; low priority)
* Distinct-from: 8.24 (AI-Filter chunked body) — different defect: 8.24 is the
  mock not reading chunked bodies; 8.53 is a logging-threshold observation.

### Issue 8.54: Stale usrloc contacts from retired bridge replicas linger and can fork 5G→2G traffic
* Symptom: `state/kamailio/kamailio.db` `location` table held contacts for
  `15551234567@10.89.0.54:5090` and `@10.89.0.55:5090` (previous bridge
  replicas) alongside the live `10.89.0.53:5090` — messages to the phone would
  fork to dead bridge IPs.
* Root Cause: usrloc `db_mode=2` write-back persists contacts across restarts;
  when the replica count dropped from 3 to 1 the dead contacts were never
  expired/deregistered (their 1800 s Expires was refreshed by the old
  instances before they died, or Kamailio restarts flushed the memory table
  while the DB kept stale rows).
* Fix: on a scale-down, deregister or prune stale contacts
  (`kamcmd ul.rm`), or restart Kamailio AND clear the location table. Check
  `sqlite3 state/kamailio/kamailio.db "SELECT username,contact FROM location"`
  after any replica change. The 5G→5G twin-relay test (Cell 4) works because
  it uses the live contact, but forked retries to dead IPs can surface as
  latency/timeouts.
* Verification: observed 2026-08-14 — the location table held
  `15551234567@10.89.0.54:5090` and `@10.89.0.55:5090` alongside the live
  `10.89.0.53:5090`; after pruning the stale rows the phone AOR had a single
  binding and calls routed to the live contact only.
* Status: AO (observed 2026-08-14; cleanup procedure, no code change yet)
* Distinct-from: 8.37 (stale demo registrations mask retry flow) — different
  source: 8.37 is leftover simulator registrations for a single AOR; 8.54 is
  dead bridge-replica contacts surviving a scale-down.

### Issue 8.55: SMPP `short_message` encoding — OsmoSMSC expects UNPACKED 7-bit chars with data_coding=0, not pre-packed GSM-7
* Symptom: 5G→2G SMS delivered via the bridge displayed as raw packed garbage
  on the 2G MS (`EY_T;J�...`) when the bridge sent `gsm7_encode()` output with
  `data_coding=0x00`.
* Root Cause: with data_coding=0, OsmoSMSC expects ONE OCTET PER SEPTET
  (sm_length = character count) and packs to GSM-7 itself for the radio path.
  Sending pre-packed septets double-encoded the message.
* Fix: `smpp_submit_sm` sends `message.encode("ascii", errors="replace")`
  (unpacked). A/B proven by `scripts/testing/smpp_ab_test.py` (packed →
  garbled, ascii → clean) and updated unit test
  (`test_submit_sm_payload_is_unpacked_ascii`).
* Verification: `smpp_ab_test.py` — packed payload displayed as raw packed
  garbage on the 2G MS; ascii payload displayed clean. Unit suite 33/33 green.
* Status: X (fixed 2026-08-14)
* Verified-by: smpp_ab_test.py A/B + unit test + live 5G→2G delivery clean

### Issue 8.56: Cross-client `+`/`00`/`0`-prefixed From: breaks OCS balance lookup → SMS wrongly blocked as "Prepaid balance exhausted" (403)
* Symptom: a message sent from the Java SipClient (or any client emitting
  international-format From:, e.g. `From: <sip:+15551234567@...>` or
  `00`/`0`-prefixed) was intercepted, then BLOCKED by the API with
  `{"allow":false,"reason":"Prepaid balance exhausted"}` even though the
  sender had balance 100. Scripted senders (`ims_terminal.py`) use bare
  MSISDNs, so the SMS matrix never caught it.
* Root Cause: Kamailio's `route[INTERCEPT_SMS]` passed `$fU` VERBATIM into the
  intercept payload; the API's OCS check `subscriberService.getBalance(sender)`
  looks up `+15551234567` in the SQLite subscriber DB, which stores BARE
  MSISDNs (`15551234567`) — the lookup misses, balance reads 0, and the SMS is
  blocked. `route(NORMALIZE)` only rewrites `$rU` (recipient) later via
  `dp_translate`; the sender was never normalized.
* Fix: `route[INTERCEPT_SMS]` now normalizes `$fU` into `$var(sender)` BEFORE
  building the payload (strip `+20`→20, `+<cc>`→bare, `00[20]`→bare,
  `0`→bare) and the jansson payload uses `$var(sender)`. One gate — every
  client (Java SipClient, MizuDroid, Linphone intl mode) benefits.
* Verification: live 2026-08-14 cross-client test — `From: <sip:+15551234567@..>`
  message now passes interception (allowed/relayed) instead of 403;
  `podman logs mvno-kamailio` shows `SMS INTERCEPT QUERY: sender=15551234567`
  (bare) in the payload. Unit + config-compile green.
* Status: X (fixed 2026-08-14, `configs/kamailio/kamailio.cfg`)
* Verified-by: live Java-style `+`-prefixed message through the full
  intercept→relay→SMPP chain on 2026-08-14
* Distinct-from: 8.38 (stale init-db seed balance) — different defect: 8.38 is
  the seeded `balance=100` never correcting; 8.56 is a live lookup keyed on a
  `+`-prefixed MSISDN missing in the DB.
* Distinct-from: 8.51 (bracketless To drop) — different header: 8.51 is the
  bridge's To parse rejecting bare form; 8.56 is Kamailio sending an
  unnormalized From to the API.

### Issue 8.57: SMPP bind_response trailing system_id octet shifts SUBMIT_SM response parse → bogus non-zero status 0x04000000
* Symptom: the bridge logged `SMPP BIND_TRANSCEIVER OK` but every SUBMIT_SM
  returned a bogus non-zero status `0x04000000` while the SMS was actually
  stored AND delivered to the 2G MS — misleading delivery-state accounting and
  noisy per-message "FAILED" logs.
* Root Cause: OsmoSMSC appends a 1-byte EMPTY `system_id` to its
  `bind_transceiver_resp` body, making the PDU 17 bytes (header 16 + 1). The
  bridge read only the 16-byte header, leaving the stray octet in the socket;
  the next `SUBMIT_SM` response parse started one byte late, so the status
  field was read shifted and decoded as `0x04000000` instead of `0x00000000`.
* Fix: after bind, read `bind_clen = struct.unpack(">I", resp[:4])[0]` and
  drain `bind_clen - 16` extra bytes (`_recv_exact(s, bind_clen - 16)`)
  before sending SUBMIT_SM.
* Verification: unit suite + live 5G→2G delivery now logs
  `[SMPP] SUBMIT_SM OK` with status 0; no stray-octet shift. 33/33 tests green.
* Status: X (fixed 2026-08-14, `scripts/ip_sm_gw.py`)
* Verified-by: live delivery chain (5G→2G SMS matrix green) + unit test

### Issue 8.58: Kamailio SMS intercept JSON built by string concatenation breaks on any body containing a double-quote
* Symptom: an SMS body containing a `"` (or backslash/control char) produced a
  malformed JSON payload to the API (`{"content":"say \"hi\""}` truncated),
  which could 400 the intercept call or corrupt the stored content. The old
  code hand-escaped via `s.replace` chains that never handled `"` correctly.
* Root Cause: `route[INTERCEPT_SMS]` assembled the payload with string concat
  + `s.replace` escaping — fragile and incorrect for quote/backslash/control
  characters; the SMS body is attacker-controlled content.
* Fix: build the payload with `jansson_set("string", ...)` so the JSON
  serializer escapes natively. NOTE (empirical): `jansson_set` creates the
  object from an UNINITIALIZED `$var(payload)`; a literal `""` initializer
  makes it fail with "result has json error" — the cfg initializes
  `$var(payload) = "{}"` and jansson_set then adds the three fields.
* Verification: config `kamailio -c` compiles; live message with an embedded
  `"` is relayed with a well-formed payload (`SMS INTERCEPT PAYLOAD` log shows
  valid escaped JSON); 2G MS receives the literal text.
* Status: X (fixed 2026-08-14, `configs/kamailio/kamailio.cfg`)
* Verified-by: live quoted-body relay 2026-08-14 + `kamailio -c` clean
* Distinct-from: 8.24 (chunked body mock) — different defect: 8.24 is the API
  mock not reading chunked bodies; 8.58 is Kamailio's payload serialization.

### Issue 8.59: demo-verify.sh rig-call gate false-FAILs — hardcoded RTP ports, buffered ctrl socket read, and a stuck call from a manual test
* Symptom: the `[3/6] RIG CALL` gate failed with "call not established" and
  "RTP packets" even though the media plane was perfect (two clean RTP
  streams, 0% loss, 7811 packets). Manual dials produced CALL_ESTABLISHED.
* Root Cause (three harness defects): (1) the tshark decode used HARDCODED
  ports `10000`/`10022`, but rtpengine assigns dynamic ports from the
  10000-20000 pool (observed 10032/10044) — `-Y rtp` matched nothing;
  (2) the dial used `timeout 3 cat <&3 | grep -q CALL_ESTABLISHED`: podman
  exec buffers the pipe, so events only reached grep when the socket closed —
  a call establishing in 0.5 s looked like a 12 s timeout; (3) a call left up
  by an earlier MANUAL test was never hung up (the cleanup used a wrong
  netstring length prefix `7:` for the 20-char `{"command":"hangup"}`), and
  baresip-rx with an active call refuses to auto-answer a second INVITE.
* Fix: (a) decode the WHOLE range `udp.port==10000-20000`;
  (b) new `scripts/testing/baresip_dial.py` — a netstring-aware python helper
  inside the rigs (`/cfg/baresip_dial.py`) that returns the instant
  CALL_ESTABLISHED is observed (proven 0.6 s warm); (c) the gate now hangs up
  BOTH rigs before dialing, using the CORRECT `${#HANGUP_MSG}:` length prefix
  (20), and `state/baresip/rx/config` gained `ctrl_tcp_listen 0.0.0.0:4444` so
  rx's side can be cleared too.
* Verification: full cold-start `demo-verify.sh` — ALL GATES PASS (exit 0)
  twice, incl. `call established (tx->rx)` and `RTP packets (7811) / loss
  0.0%`; repeated runs green.
* Status: X (fixed 2026-08-14, `scripts/testing/demo-verify.sh` +
  `scripts/testing/baresip_dial.py` + `state/baresip/rx/config`)
* Verified-by: two consecutive full cold-start gate runs green on 2026-08-14
* Distinct-from: 8.29 (baresip ctrl_tcp netstring dialing) — different
  defect: 8.29 documented the netstring framing/protocol; 8.59 is the GATE's
  buffered-pipe read + wrong-length-prefix hangup + hardcoded ports.

### Issue 8.60: Bridge `reply_ok()` split on `\r\n` only — bare-LF (MizuDroid) MESSAGEs delivered but never ACKed to the sender
* Symptom: a bare-LF SIP MESSAGE (MizuDroid/embedded-style line endings) was
  relayed by the bridge and delivered to the 2G MS, but the SENDER never
  received the final 200 OK — Kamailio retransmitted the MESSAGE twice (two
  `[RELAY]` lines in the bridge log) and the sending terminal showed a
  timeout. CRLF requests (Linphone, Java SipClient, baresip) were fine — which
  hid the bug.
* Root Cause: `reply_ok()` split the request on `"\r\n"` ONLY. A bare-LF
  request therefore collapsed into ONE line: no Via/From/Call-ID/CSeq headers
  were found, so the 200 OK was sent with EMPTY transaction headers —
  Kamailio's tm could not match it to the in-flight transaction and kept
  retransmitting. The SMS was stored + delivered; only the ACK was lost.
* Fix: `reply_ok()` normalizes line endings first
  (`req_text.replace("\r\n", "\n").split("\n")`) before extracting Via/From/
  To/Call-ID/CSeq, so the 200 OK carries the transaction headers regardless of
  the request's line-ending convention. Regression tests added
  (`test_reply_ok_carries_headers_for_bare_lf_request` and the CRLF twin) —
  suite now 35/35.
* Verification: live 2026-08-14 cross-client run — MizuDroid-style bare-LF
  message now gets `SIP/2.0 200 OK` (was TIMEOUT), message relayed + SMPP
  SUBMIT_SM OK + delivered to the 2G MS `sms.txt`; Java-style `+`-prefixed
  CRLF message also 200 OK.
* Status: X (fixed 2026-08-14, `scripts/ip_sm_gw.py` + 2 tests)
* Verified-by: live bare-LF MESSAGE 200 OK + sms.txt delivery on 2026-08-14
* Distinct-from: 8.51 (bracketless To drop) — different layer: 8.51 is header
  PARSING of the incoming request; 8.60 is the outbound 200 OK assembly (no
  headers at all) for bare-LF requests.
* Distinct-from: 8.25 (Via: Via: malformed 200) — different defect: 8.25 was a
  duplicated `Via:` prefix; 8.60 is MISSING transaction headers entirely for
  bare-LF input.

### Issue 8.61: 2G radio paging stalls after long idle — MT-SMS queued in smsc.db but never paged to the MS (transient)
* Symptom: mid-session (2026-08-14) 5G→2G messages were relayed by the bridge
  and SUBMIT_SM'd OK (`[SMPP] SUBMIT_SM OK`), but the 2G MS `sms.txt` never
  received them — the SMSC logged `Paging Response action (expired)` for
  IMSI-001010000000004 and the rows stayed `sent=NULL` in `smsc.db`.
  A raw SMPP control message sent BEFORE the stall (XC-JAVA-0814) delivered
  fine; the stall started mid-session after the 2G MS sat idle for hours.
* Root Cause: transient 2G radio path degradation (LAPD `MDL-ERROR-IND cause
  3` / SDCCH `Unsolicited UA response` on mvno-2g-core; the virtual Um link
  stopped delivering paging responses). Not a bridge/SMPP/Kamailio defect —
  the messages were stored + accepted by the SMSC; the radio leg failed to
  page. The SMS matrix passed ALL CELLS earlier the same day, so this is a
  time-dependent 2G radio flake, not a code regression.
* Fix (recovery runbook): restart the 2G chain atomically and re-attach the MS
  (`podman restart mvno-2g-core mvno-osmosmsc mvno-2g-ms`), then wait for the
  MS location update (`msc_a_fsm... LU` complete + `EVENT_REG_SUCCESS` in the
  MS log) before re-sending. Rows whose retry cycles were exhausted stay in
  smsc.db `sent=NULL` — re-submit fresh messages rather than waiting for them.
* Verification: after the chain restart + MS re-attach, a fresh SMPP message
  (RADIOOK-0814) delivered to sms.txt within ~25 s. The earlier queued rows
  (id 81-87) had exhausted their retries during the stall and were
  re-submitted fresh.
* Status: AO (observed 2026-08-14; transient infra flake, recovery runbook
  only — no code change)
* Distinct-from: 8.54 (stale usrloc contacts) — different layer: 8.54 is
  Kamailio routing to dead bridge replicas; 8.61 is the 2G radio paging leg.

### Issue 8.62: Asterisk media-server sidecar — conference / voicemail / screening behind Kamailio (IMPLEMENTED)
* Symptom (feature, not a fault): the interception core (Kamailio + rtpengine)
  cannot MIX audio — rtpengine is a media relay/NAT anchor, not an MCU — so
  conference calling, voicemail, and IVR call-screening had no home; the
  decision doc recommended an Asterisk sidecar (ARCHITECTURE_DECISIONS.md D7).
* Fix: added `mvno-asterisk` (Asterisk 20.6, Ubuntu 24.04 container — Debian
  12 DROPPED the `asterisk` package so Ubuntu is used, matching the decision
  doc + the baresip rig's base) at 10.89.0.63 on the bridge net; Kamailio
  routes feature numbers to the SIP trunk at :5061:
  - `7XXX` → ConfBridge room (conference calling)
  - `8XXX` → VoicemailMain mailbox
  - `8000` → screening demo: record name → accept (Dial rig callee as
    registered UA 15550000001) / decline / leave a message
  Configs in `configs/asterisk/`; compose service + build/save entries in
  bootstrap.sh; screening subscriber provisioned via add-subscriber.sh.
* Issues hit while implementing (documented here so nobody re-hits them):
  (a) `asterisk` package absent from Debian 12 main → Ubuntu 24.04 base;
  (b) `app_voicemail_imap.so`/`_odbc.so` clobber the file-based VoiceMailMain
  registration (`noload` them in modules.conf);
  (c) Asterisk needs `/var/lib/asterisk/documentation` (symlink to
  /usr/share) or "Stasis initialization failed. ASTERISK EXITING!";
  (d) Ubuntu modules live in /usr/lib/x86_64-linux-gnu/asterisk/modules;
  (e) confbridge.conf: no `max_members` in [general] (Asterisk 20), no `#`
  menu key, no `pin` on open rooms.
* Verification: live 2026-08-14 — ConfBridge 001 held TWO callers
  (15553332211 + 15559998888) with RTP recorded (2288 pkts, 0% loss) and a
  clean hangup; VoicemailMain executed; screening Record() saved the caller
  WAV and the accept-leg Dial connected to the rig callee
  (`Call established: sip:15550000001@10.89.0.23` in baresip-rx).
* Status: X (implemented 2026-08-14)
* Verified-by: live conference + voicemail + screening-accept-leg on
  2026-08-14 (confbridge list, core show channels, baresip-rx log)
* Distinct-from: 8.29/8.59 (baresip ctrl_tcp) — different component: 8.29/8.59
  are the baresip rig console/gate; 8.62 is the new Asterisk media server.

### Issue 8.63: Kamailio jansson_set() fails on raw $rb causing false-positive SMS blocks on mobile clients (jansson-body)
* Symptom: When an external client (e.g. Android Linphone) sends a SIP MESSAGE, Kamailio logs:
  `ERROR: jansson [jansson_funcs.c:189]: janssonmod_set(): value to add is not a string - "content"`
  `WARNING: <script>: SMS BLOCKED BY MVNO INTERCEPTION CORE (jansson allow=false): 15551234567 -> 1555...`
  The message was rejected with `403 Forbidden - SMS Blocked` and Linphone displayed delivery status `0 0 0 0` / undelivered.
* Root Cause: `$rb` is a raw body buffer pseudo-variable. In Kamailio 5.7 `jansson_set("string", "content", "$rb", "$var(payload)")` fails if `$rb` contains null, binary, or non-string PV properties without explicit assignment to a string pseudo-variable `$var(content)` (the jansson-body serialization defect). When `jansson_set` failed, `$var(payload)` lacked the `"content"` key, causing `mvno-api` to receive a malformed request or trigger downstream failure, falling into Kamailio's `if ($var(allow) != 1)` 403 block.
* Fix: Coerce `$rb` to an explicit string variable `$var(content) = $rb; if ($var(content) == $null || $var(content) == "") { $var(content) = " "; }` before passing to `jansson_set("string", "content", "$var(content)", "$var(payload)")` in `configs/kamailio/kamailio.cfg` `route[INTERCEPT_SMS]`.
* Verification: Tested live 2026-08-14 — Linphone MESSAGE from `15551234567` ("message from ziad" and "a sms from mobile...") was accepted with 200 OK and successfully delivered into `/root/.osmocom/bb/sms.txt` on `mvno-2g-ms`.
* Status: X (fixed 2026-08-14, commit `218dabe`)
* Verified-by: live Linphone MESSAGE 200 OK + `sms.txt` inbox receipt on 2026-08-14
* Distinct-from: 8.58 (`jansson` missing from Alpine package) — different defect: 8.58 was module loading failure; 8.63 is parameter PV type evaluation inside `jansson_set`.

### Issue 8.64: ffmpeg PulseAudio capture hangs with exit 124 in background/subshell scripts without -nostdin (nostdin)
* Symptom: `mic_probe.sh` or automated scripts hanging with exit code 124 (timeout) during `ffmpeg -f pulse` execution with 0 stderr captured (`FATAL: 3 s Pulse capture failed after retry`).
* Root Cause: `ffmpeg` attempts to read terminal keyboard control characters from standard input (`stdin`). When spawned from non-interactive subshells, background scripts, or cron/tmux jobs, `ffmpeg` stalls waiting on stdin instead of streaming from the PipeWire PulseAudio socket (missing the nostdin flag).
* Fix: Pass `-nostdin` flag to all automated `ffmpeg` capture invocations in `scripts/demo/mic_probe.sh`, `mic_verify.sh`, and `scripts/testing/`.
* Verification: `bash scripts/demo/mic_probe.sh` executes synchronously in 7s without hanging, capturing 3s of live ambient audio at `-42.8 dB` with `exit_code == 0`.
* Status: X (fixed 2026-08-14, commit `218dabe`)
* Verified-by: `bash scripts/demo/mic_probe.sh` clean pass (exit 0) on 2026-08-14
* Distinct-from: 8.47 (baresip container pulse mount) — different defect: 8.47 was container socket permission/labels; 8.64 is `ffmpeg` CLI stdin blocking in subshells.

### Issue 8.65: Broken REPO_ROOT path calculation (/..) in scripts/demo/ user scripts (repo-root)
* Symptom: `user_demo.sh`, `user_call.sh`, and `user_sms.sh` failed with `No such file or directory` when calling helper scripts in `scripts/testing/` or `scripts/demo/`.
* Root Cause: `REPO_ROOT` was defined as `$(cd "$(dirname "$0")/.." && pwd)` inside `scripts/demo/*.sh`, resolving to `.../MVNO/scripts` instead of the repository root `.../MVNO` (`/../..`) — the repo-root path defect.
* Fix: Updated `REPO_ROOT` calculation to `/../..` across `user_demo.sh`, `user_call.sh`, and `user_sms.sh`.
* Verification: `bash scripts/demo/user_sms.sh` and `user_demo.sh` resolve paths correctly and execute without missing script errors.
* Status: X (fixed 2026-08-14, commit `218dabe`)
* Verified-by: `user_demo.sh` menu launch and `user_sms.sh` execution on 2026-08-14
* Distinct-from: 8.45 (cold-start path conventions) — different scope: 8.45 is Makefile targets; 8.65 is subshell relative directory resolution.

### Issue 8.66: Linphone IMDN delivery notification badge mismatch with standard transport SIP 200 OK (imdn)
* Symptom: Linphone displays `0 0 0 0` / pending delivery icon for standard SIP MESSAGEs because Linphone's chat engine by default expects RFC 5438 IMDN XML delivery receipts (`application/imdn+xml`) from the SIP server, while standard SIP SMS gateways only return transport-level `SIP/2.0 200 OK`.
* Root Cause: Linphone 6.x default chat mode treats SIP MESSAGE as an IM session requiring RFC 5438 positive delivery notifications (`<imdn><delivery-notification><status><delivered/></status></delivery-notification></imdn>`). When only SIP 200 OK is returned, the message is physically delivered to the SMSC/recipient, but the UI keeps the badge in unconfirmed state due to missing imdn receipts.
* Fix: Documented in `docs/device-registration-linphone-mizudroid.md` to disable "Request delivery notifications" / "IMDN" in Linphone Advanced Settings, or accept that transport 200 OK delivers the message to the 2G/5G queue.
* Verification: Verified message landing in `/root/.osmocom/bb/sms.txt` while Linphone showed pending status badge.
* Status: AO (observed and documented 2026-08-14)
* Verified-by: 2G MS receipt log vs Linphone UI badge comparison on 2026-08-14
* Distinct-from: 8.52 (typing indicator filter) — different RFC: 8.52 is RFC 3994 iscomposing XML; 8.66 is RFC 5438 IMDN delivery receipts.

### Issue 8.67: Baresip ausine/aufile module shadowing live pulse.so audio streaming during active calls (ausine-shadowing)
* Symptom: Calls establish cleanly (CALL_ESTABLISHED in 0.6s) and PipeWire VoIP Player / Recorder streams open, but no real microphone or speaker audio is audible on the host; container logs show `audio rx pipeline: aufile <--- aubuf <--- PCMU` and `audio tx pipeline: ausine ---> aubuf ---> PCMU`.
* Root Cause: When `module ausine.so` and `module aufile.so` are loaded in Baresip's `config` alongside `pulse.so`, Baresip's internal module registry gives priority to the test tone and WAV file writer modules, suppressing the live PulseAudio hardware stream (the ausine-shadowing defect).
* Fix: Removed `ausine.so` and `aufile.so` from dynamic `state/baresip/*/config` and updated `scripts/testing/demo_call.sh` to only load `pulse.so` when `PULSE_OK=1` (host PulseAudio present), and load `ausine.so`/`aufile.so` exclusively during headless CI/CD fallback (`PULSE_OK=0`).
* Verification: Verified live call on 2026-08-14 — `podman logs baresip-rx` confirmed `audio tx pipeline: pulse ---> aubuf ---> PCMU` and `audio rx pipeline: pulse <--- aubuf <--- PCMU` with real two-way hardware audio streaming.
* Status: X (fixed 2026-08-14)
* Verified-by: live baresip-rx audio pipeline log (`pulse ---> aubuf`) on 2026-08-14
* Distinct-from: 8.47 (baresip container pulse mount) — different defect: 8.47 was socket permissions and SELinux label; 8.67 is module ordering/priority inside baresip.conf.

### Issue 8.68: Kamailio Asterisk feature route missing t_on_reply(RTP_ANSWER) leaking container IP to WiFi handsets (asterisk-rtp-answer)
* Symptom: When an external WiFi handset (e.g. Android Linphone at 192.168.100.34) calls Asterisk feature extensions (`7XXX` ConfBridge or `8000` Screening), the call establishes and Asterisk transmits audio (`Transmit: >4000 pkts`), but Asterisk receives 0 packets from the handset (`Receive: 0 pkts`), causing one-way silence on the conference bridge.
* Root Cause: In `configs/kamailio/kamailio.cfg`, the Asterisk feature block (`if ($rU =~ "^(7[0-9]{3}|8[0-9]{3})$")`) called `t_relay_to_udp("10.89.0.63", "5061")` without arming `t_on_reply("RTP_ANSWER")` (the asterisk-rtp-answer routing defect). When Asterisk emitted `200 OK` with its internal container IP (`c=IN IP4 10.89.0.63`), RTPEngine did not rewrite the SDP answer, sending an unroutable Podman subnet IP to the external WiFi phone.
* Fix: Added `t_on_reply("RTP_ANSWER");` before `t_relay_to_udp()` in `configs/kamailio/kamailio.cfg` and restarted Kamailio.
* Verification: Verified live 2026-08-14 — RTPEngine rewrote Asterisk's 200 OK SDP to `192.168.100.93`, and Asterisk `pjsip show channelstats` confirmed bidirectional RTP packet flow (`Receive: >0 pkts`).
* Status: X (fixed 2026-08-14, commit `aa531c6`)
* Verified-by: live ConfBridge 001 channelstats bidirectional RTP on 2026-08-14
* Distinct-from: 8.62 (Asterisk sidecar) — different aspect: 8.62 is the sidecar service integration; 8.68 is the Kamailio onreply SDP rewriting trigger.

---

## 10. Cross-Repo Integration Contract Specifications

> **Synopsis — the authoritative contract is `docs/INTEGRATION_CONTRACT.md`
> (v1.2, verified 2026-08-09).** This section is a memory hook for the
> multi-repo boundaries inside the `AI-SpamFilter-PMN` org. On any conflict
> with the contract file, **the contract wins** — full payload schemas,
> SLA/fail-open, credentials, and per-repo notes live there and are **not**
> restated here (they have already drifted once; see the sms-client note).

### 1. `ai-filter` Model Container Interface (`AI-Filteration-System` Repo)
- `POST /api/v1/classify` on `ai-filter:8000` (container) / host `8008`; **three event types**
  (`SMS`, `VOICE_CALL`, `TRANSCRIPT`); response `{ "allow": bool, "reason": string }`;
  SLA ≤ 5 s read with fail-open + circuit breaker — see INTEGRATION_CONTRACT §3–§4.

### 2. `sms-client` SMPP Client Interface (Ali — `sms-client` Repo)
- ⚠ **Current refactored client does NOT target MVNO today**: it runs its own SMPP `:2076`
  + Neon + login (`origin/main @ 1a388af`). The classic MVNO seam is `osmo-smsc:2775`
  (SMSC System-ID `MVNO_SMSC`; ESME `mvno-api-route`/`changeme` primary,
  `smsclient`/`password` secondary). The **planned** org flow re-points the client to the
  Filteration-System decider `:2076` first (see INTEGRATION_CONTRACT §5 + handoff).
- REST interception: `POST /api/v1/intercept/sms` on `telecom-api:8080` with
  `X-API-Key: mvno-demo-key-2026` (missing/mismatched → `401`).

### 3. `SipClient` User Agent Interface (`SipClient` Repo)
- SIP UDP at `127.0.0.1:5060` (host) → `kamailio:5060/udp`; works for any RFC-3261 softphone
  (desktop/mobile), not just this repo's client — see LIVE_DEMO S15. REGISTER **and** INVITE are
  digest-challenged (realm `localhost`, subscriber-table creds; `407` → retry with
  `Authorization: Digest`). RTP relay `10000-20000/udp`, **PCMU only** (no transcode).

---

## 11. Not-Issues (verified non-faults / agent artifacts)

> Quarantine for suspected issues that were investigated and **refuted** — a
> tool mishap, a probe artifact, or an agent over-claim. Filed here as `C`
> (closed non-fault) so nobody re-investigates them. `check-issues.sh` treats
> anything in this section as background, not as an open defect. Every entry
> must state why it is NOT a fault.

### Not-Issue N-1: Watchdog `--self-test` "unguarded `podman stop` mid-demo" (audited-and-clear)
* **Claim**: `--self-test` runs `podman stop mvno-ip-sm-gw` unconditionally at the top and could tear down an in-flight demo call.
* **Why it is NOT a fault**: `recover()` calls `demo_running()` (lock files + `mvno-live` tmux session + pgrep gate/sms_matrix/live_demo/demo_live) and skips recovery when a demo is in flight — the stop → recover path is guarded by design.
* **Status**: C · audited 2026-08-08 (previously noted under Issue 8.43; moved here so the claim is not re-filed).

### Not-Issue N-2: tshark RTP decode-direction concern (audited-and-clear)
* **Claim**: `-d udp.port==10000-20000,rtp` might decode 0 frames because the media relay uses only source ports, false-FAILing the proof harness.
* **Why it is NOT a fault**: compose maps `10000-20000:10000-20000/udp` (1:1, both directions), so `udp.port==10000-20000` matches src and dst — the RTP decode works both ways.
* **Status**: C · audited 2026-08-08 (moved here from the Issue 8.43 note).

### Not-Issue N-3: rootless passt UDP port-forward silently drops replies to unbound test sockets (and Via-port ≠ source-port)
* **Claim**: "Kamailio stopped answering" — a custom cross-client test script sent SIP MESSAGEs from an UNBOUND socket (ephemeral port) and got NO response (not even the 407), while `ims_terminal.py` worked.
* **Why it is NOT a fault**: the rootless podman passt forwarder tracks UDP flows from the CONTAINER side; it only returns packets to the host port the client actually bound (the host source port). An unbound socket uses a random ephemeral source port per datagram, and (second gotcha) the Via header port must MATCH the bound source port — a mismatch (Via 5075, bound 5090) also gets silently dropped. Real SIP clients (Linphone, MizuDroid, Java SipClient) always bind their listen socket and set Via = source port, so this never affects production traffic — it is a harness-writing requirement: BIND the socket and keep Via == bound port (verified: bound 5090 + Via 5090 → 407; unbound → timeout; bound 5090 + Via 5075 → timeout).
* **Status**: C · audited 2026-08-14 (test-harness artifact; documented in TESTING_REFERENCE so future scripts bind correctly).

### Not-Issue N-4: Android keyguard/pattern bouncer blocked UI-automation taps during phone call testing (device-state artifact)
* **Claim**: "the phone never answers — the stack is broken" — during the laptop→phone call verification, adb `input tap` on the Linphone Answer slider did nothing.
* **Why it is NOT a fault**: the phone's screen had fallen asleep mid-test and the pattern/PIN keyguard bouncer (`AlternateBouncerView`) covered the call UI; `uiautomator dump` showed zero Linphone nodes and `dumpsys window` showed `NotificationShade`/bouncer focused. The call itself rang correctly (the incoming-call UI was verified earlier in the same session); the stack (Kamailio routing, rtpengine, Vosk) was healthy. Harness fix: `adb shell svc power stayon true` + dismiss keyguard before UI automation, and prefer the call NOTIFICATION's Answer action over the full-screen slider.
* **Status**: C · audited 2026-08-14 (test-environment artifact, not a code defect).
