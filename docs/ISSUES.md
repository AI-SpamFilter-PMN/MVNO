# Telecom & Cloud-Native System Issues, Root Causes, and Verification Reference (`ISSUES.md`)

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
This document is the authoritative troubleshooting, root-cause analysis, and deployment architecture reference for the MVNO Interception Core. It details every technical issue encountered across Osmocom, Kamailio, RTPEngine, Open5GS, VictoriaMetrics, Grafana, Vector, and UERANSIM, along with empirical verification steps and deployment models (Native, Containerized, and Mixed).

---

## 1. Architectural & Deployment Model Taxonomy

### Native vs. Containerized vs. Mixed Deployments

| Component | Native Deployment (Systemd / Scripts) | Containerized Deployment (Podman / Docker) | Mixed / Hybrid Deployment |
|---|---|---|---|
| **Osmocom (MSC/HLR)** | Installed via `apt install osmo-msc osmo-hlr`. Configs at `/etc/osmocom/`. Runs under `osmocom` user. | Built from `debian:bookworm-slim` binary packages. VTY bound to container network. | Native MSC/HLR connected to Containerized Gateway & 5GC via bridge interface. |
| **Kamailio** | Installed via `apt install kamailio`. Modules at `/usr/lib/x86_64-linux-gnu/kamailio/modules/`. | Custom Alpine 3.19 build (`mvno-kamailio`). Modules at `/usr/lib/kamailio/modules/`. | Native Kamailio bound to host port 5060, communicating with containerized RTPEngine via `127.0.0.1:22222`. |
| **RTPEngine** | Native kernel module `xt_RTPENGINE` + daemon. High packet throughput. | Userspace packet forwarding (`drachtio/rtpengine:latest`). Bound to UDP `30000-30100`. | Native kernel module with containerized signaling proxy. |
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
* **Fix**: Updated `docker-compose.yml` port mapping for Kamailio to `5066:5060/udp`.

### Issue 3.6: Unauthenticated SIP INVITE Proxying (Zero-Trust Section 1.1)
* **Symptom**: Any unauthenticated SIP client could trigger policy interception calls and reach RTPEngine — no credential check on inbound `INVITE` dialogs.
* **Root Cause**: `configs/kamailio/kamailio.cfg` only enforced digest auth on `REGISTER`; the `INVITE` branch proxied straight into `route[INTERCEPT]` with no `auth_db` challenge.
* **Fix**: Added a 407 digest challenge on the `INVITE` branch in [kamailio.cfg](configs/kamailio/kamailio.cfg): `if ($au == "" && !auth_check("$fd","subscriber","1")) { auth_challenge("$fd","0"); exit; }` before `route(INTERCEPT)`. Updated [sip_traffic_sim.py](scripts/testing/sip_traffic_sim.py) with a full 407→digest→INVITE handshake (`send_sip_invite(caller, callee, password)`), and rewrote runbook step 6 to assert the handshake still yields `403 Forbidden` for zero-balance callers. Verified live: unauth INVITE → `407 Proxy Authentication Required`; valid digest + zero balance → `403`; `REGISTER` flow unaffected.

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
* **Status**: > [!NOTE] Superseded by Issue 8.12 (unified mount `./state/kamailio/kamailio.db`).

### Issue 6.2: `vmagent` Promscrape Configuration Flag Omission
* **Symptom**: VictoriaMetrics (`:8428`) and Grafana NOC Dashboards (`:3000`) rendered empty metric panels with zero active targets.
* **Root Cause**: `vmagent` container command stanza was missing `-promscrape.config=/etc/prometheus/prometheus.yml`, causing `vmagent` to run in silent mode without loading target scrape configurations. Additionally, the target hostname in `scrape.yml` was listed as `telecom-api` instead of `mvno-api`.
* **Fix**: Added `-promscrape.config=/etc/prometheus/prometheus.yml` and exposed port `8429:8429` in `docker-compose.yml`, and updated `scrape.yml` target address to `mvno-api:8080`. Verified scrape jobs resolving to **8 active scrape target instances (8/8 health: UP)** (`amf`, `smf`, `upf`, `mvno-api`, `rtpengine`, `mongodb-exporter`, `vmagent`, `victoria-metrics`). Ingested MongoDB metrics grew from 1 to **2,372 metrics** after adding `--collect-all`.

### Issue 6.3: Grafana SQLite WAL Corruption
* **Symptom**: Grafana crashes after host reboot with `database is locked` or `disk I/O error`.
* **Root Cause**: Missing `GF_DATABASE_WAL=true` in `docker-compose.yml` environment variables.
* **Fix**: Pinned image to `grafana/grafana-oss:11.6.0` and added `GF_DATABASE_WAL=true` in `docker-compose.yml`.
* **Status**: Unapplied in initial stack compose configuration; applied in 2026-08-01 telemetry alignment.

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
* **Status**: > [!NOTE] Superseded by Issue 8.10 (SMF acts as sole PFCP client initiator per 3GPP TS 29.244).

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
* **Fix**: Added [ApiKeyInterceptor.java](telecom-api/src/main/java/com/mvno/intercept/config/ApiKeyInterceptor.java) + [WebConfig.java](telecom-api/src/main/java/com/mvno/intercept/config/WebConfig.java) (registered on `/api/v1/intercept/**`) with `intercept.api-key: ${X_API_KEY:mvno-demo-key-2026}` in `application.yml`; Kamailio callout switched to 4-arg `http_client_query(url, "", "X-API-Key: ...\r\n", res)` (empty post-data → GET with headers). All consumers keyed: Makefile `make test-api/test-sms/test-call` and runbook steps 4/7/8. `/actuator/*` intentionally left open for vmagent scraping. Verified live: missing/wrong key → `401`; valid key → normal flow; 3 new tests (`ApiKeyInterceptorTest`) → suite now 22/22.

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
| **IMS Voice Call (media plane, Issue 8.27)** | `sip_traffic_sim.py --uas … --rtp 5` + `--rtp 6` caller | `407 → 100 → 180 → 200 OK`, ACK/BYE answered, bidirectional RTP through rtpengine, `rtpengine_packets_total > 0`, recorded pcap, `pcap_to_wav.py` → Vosk `.txt` in spool/archived | ✅ **PASS** (Aug 3 2026) |
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
* **New pipeline component**: `scripts/testing/pcap_to_wav.py` — extracts G.711 (PCMU) audio from an rtpengine `recording-format=eth` pcap into a 16-bit 8 kHz WAV in `state/spool/`, which the Native Vosk ASR watcher auto-transcribes and archives (closes the roadmap gap noted in `configs/rtpengine/rtpengine.conf`: mr9.4 records pcap only).
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

* **Symptom**: `printf 'MESSAGE …' | nc -u localhost 5066` prints Kamailio's 407/200 response but **hangs** — the command never returns and the shell blocks.
* **Root Cause**: the UDP socket stays open waiting for more input after the response; this nc build (openbsd-netcat) keeps reading until stdin EOF *and* does not self-close on a datagram reply.
* **Fix**: always wrap in `timeout 5 nc -u localhost 5066 < request.txt` (and feed the request from a file, not a live terminal).
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


---

## 10. Cross-Repo Integration Contract Specifications

This section defines the multi-agent integration boundaries across team repositories within the `AI-SpamFilter-PMN` organization.

### 1. `ai-filter` Model Container Interface (`AI-Filteration-System` Repo)
- **Container Service Name**: `ai-filter` (attached to `mvno_net` bridge network).
- **Listening Socket**: `0.0.0.0:8000` inside container.
- **REST Contract**: `POST /api/v1/classify`
- **Request Payload** (event-typed): `{ "event_type": "SMS", "sender_msisdn", "recipient_msisdn", "content_text", "timestamp_epoch_ms" }` for SMS; `{ "event_type": "VOICE_CALL", "caller_msisdn", "callee_msisdn", "call_id", "timestamp_epoch_ms" }` for voice (no `content_text`, no `call_id` on SMS — verified against `AiFilterService.java`)
- **Response Payload**: `{ "allow": boolean, "reason": string }`
- **SLA Bound**: Response time $\le 5.0\text{s}$ (Fail-open SLA fallback on timeout).

### 2. `sms-client` SMPP Client Interface (Ali — `sms-client` Repo)
- **Protocol**: SMPP v3.4 BIND_TRANSCEIVER over TCP.
- **Target Host & Port**: `osmo-smsc:2775` (inside container network `mvno_net`).
- **SMSC System-ID**: `MVNO_SMSC`
- **Primary ESME Credentials**: `mvno-api-route` / `changeme`
- **Secondary Client ESME Credentials**: `smsclient` / `password`
- **REST Interception Gateway**: Calls `POST /api/v1/intercept/sms` on `telecom-api:8080` with header `X-API-Key: mvno-demo-key-2026` (zero-trust Section 1.2; missing/mismatched key → `401`).

### 3. `SipClient` User Agent Interface (`SipClient` Repo)
- **Protocol**: SIP RFC 3261 over UDP.
- **Target Host & Port**: `localhost:5066` on host (maps to `kamailio:5060/udp`).
- **SIP REGISTER Authentication**: Digest authentication (`auth_check()`) using credentials seeded in `kamailio.db`.
- **SIP INVITE Authentication**: `INVITE` is also challenged (`407 Proxy Authentication Required`, zero-trust Section 1.1) — retry with `Authorization: Digest` (realm `localhost`).
- **RTP Media Streams**: RTPEngine UDP port range `30000-30100/udp` (G.711u PCMU codec).
