# Telecom & Cloud-Native System Issues, Root Causes, and Verification Reference (`ISSUES.md`)

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
* **Fix**: Added a 407 digest challenge on the `INVITE` branch in [kamailio.cfg](file:///home/zkhattab/MVNO/configs/kamailio/kamailio.cfg): `if ($au == "" && !auth_check("$fd","subscriber","1")) { auth_challenge("$fd","0"); exit; }` before `route(INTERCEPT)`. Updated [sip_traffic_sim.py](file:///home/zkhattab/MVNO/scripts/testing/sip_traffic_sim.py) with a full 407→digest→INVITE handshake (`send_sip_invite(caller, callee, password)`), and rewrote runbook step 6 to assert the handshake still yields `403 Forbidden` for zero-balance callers. Verified live: unauth INVITE → `407 Proxy Authentication Required`; valid digest + zero balance → `403`; `REGISTER` flow unaffected.

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
* **Conclusion**: h2c cleartext framing is compliant for a trusted, single-tenant bridge network (`mvno_net`) per TS 29.500 §6.1 (TLS optional when transport security is provided by the network segment). No changes required. Live evidence: `nrf` shows all NFs registered over cleartext HTTP/2; `mvno-udm`/`mvno-udr` healthy.

### Issue 5.5: `ogs_tun_set_ip()` is a No-Op on Linux — ogstun Gateway Never Configured
* **Symptom**: UPF's N6 tunnel device `ogstun` existed inside `mvno-upf` but had **no IP address and no route** (`ip addr` empty, `10.45.0.0/16` route absent). All user-plane packets written to the tun by the UPF were silently dropped by the kernel (device RX/TX counters stayed at 0). Symptom seen as "UPF receives GTP-U but no N6 write" (`[RECV] GPU-U` traces present, `ogstun` RX = 0).
* **Root Cause**: `ogs_tun_set_ip()` in Open5GS `lib/tun/linux-setup.c` is a **deliberate no-op returning `OGS_OK`** on Linux — verified identical in v2.7.7 and v2.8.0. The comment in `src/upf/gtp-path.c` states "Note that Linux will skip this configuration": on Linux the operator must configure the TUN externally (`ip tuntap add` / `ip addr add` + route). The containerized UPF entrypoint never did this, so the UPF opened `ogstun` (device created via `TUNSETIFF`) but the device had no addressing.
* **Fix**: [configs/open5gs/entrypoint.sh](file:///home/zkhattab/MVNO/configs/open5gs/entrypoint.sh) UPF branch polls for `ogstun` to appear (≤30 s), then applies:
  ```bash
  ip addr replace 10.45.0.1/16 dev ogstun
  ip -6 addr replace 2001:db8:cafe::1/48 dev ogstun
  ip link set ogstun up
  ```
  (`iproute2` added to the runtime stage of [configs/open5gs/Dockerfile](file:///home/zkhattab/MVNO/configs/open5gs/Dockerfile)).
* **Verification**: `podman exec mvno-upf ip addr show ogstun` → `inet 10.45.0.1/16`, `inet6 2001:db8:cafe::1/48`, `UP,LOWER_UP`; `ip route` → `10.45.0.0/16 dev ogstun proto kernel scope link src 10.45.0.1`. UL probe: 5 UDP packets from a UE tun reach `ogstun` RX (+165 bytes); DL probe: packets from the UPF netns reach the UE tun.

### Issue 5.6: Fresh v2.8.0 Source Rebuild Regresses SBI HTTP/2 Clients (30 s Heartbeat Death)
* **Symptom**: After rebuilding the Open5GS container from the `v2.8.0` tag source, every NF's SBI connection to the NRF died at the first heartbeat (~30-35 s after registration): `[sbi] WARNING: Error in the HTTP2 framing layer (16)` (lib/sbi/client.c:767, `CURLE_HTTP2`), followed by NRF `[nrf] WARNING: No heartbeat` → de-registration. All NFs de-registered on a fixed cadence regardless of NRF restart order.
* **Root Cause**: The freshly built daemon binaries (from-source v2.8.0 tag, verified tag peel `157f611a...` 2026-06-20 Release-19) exhibited a regressed HTTP/2 client behavior compared to the known-good 07-26 image (`mvno-open5gs:latest`, image `a2f041bbd267`). A 2×2 matrix (old/new image × NRF/client) proved: any *new-image client* fails; any *known-good client* works against either NRF. Runtime libraries were byte-identical (libcurl3-gnutls 7.88.1-10+deb12u15, libgnutls30 3.7.9-2+deb12u7, libnghttp2-14 1.52.0-1+deb12u3, libssl3 3.0.20-1~deb12u2); only the Open5GS daemon binaries differed (md5).
* **Fix**: [configs/open5gs/Dockerfile](file:///home/zkhattab/MVNO/configs/open5gs/Dockerfile) is now **layered on the known-good image** (`FROM mvno-open5gs:latest`) adding only `iproute2` + the fixed `entrypoint.sh` — it does **not** rebuild Open5GS from source. The Dockerfile carries an explicit banner: do not switch the base back to a fresh source build until the HTTP/2 client regression is root-caused upstream. Rebuilt image `mvno-open5gs:2.8.0` daemon binaries now md5-match the known-good image.
* **Verification**: Full stack recreate → NRF shows 8 NF registrations, **0 de-registrations** past the 90 s heartbeat checkpoint; only a few startup-race framings (all before the settle timestamp), none after.

### Issue 5.7: SMF UE Pool Allocates the ogstun Gateway Address (10.45.0.1) to UEs
* **Symptom**: Intermittently a UE was handed `10.45.0.1/32` — the same address as the `ogstun` gateway (e.g. wave 1: ue-1=.3, ue-2=**10.45.0.1**, ue-3=.4). Traffic to `10.45.0.1:9` from that UE self-routed into its own tun, breaking probes and shadowing the real gateway.
* **Root Cause**: `configs/open5gs/smf.yaml` session stanza declared only `subnet: 10.45.0.0/16`, so the SMF's allocatable UE pool began at the subnet base — including the gateway address the UPF's ogstun uses.
* **Fix**: [configs/open5gs/smf.yaml](file:///home/zkhattab/MVNO/configs/open5gs/smf.yaml):
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
* **Fix**: Replaced `|| vector(0)` with `default 0` (e.g. `sum(mvno_sms_requests_total) default 0`) across [configs/grafana/provisioning/dashboards/mvno_unified_noc.json](file:///home/zkhattab/MVNO/configs/grafana/provisioning/dashboards/mvno_unified_noc.json).

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
* **Fix**: Added `loadmodule "http_client.so"` and `route[INTERCEPT]` using `http_client_query("http://mvno-api:8080/api/v1/intercept/call", ...)` before location lookup in [configs/kamailio/kamailio.cfg](file:///home/zkhattab/MVNO/configs/kamailio/kamailio.cfg).

### Issue 8.4: Open5GS SBI HTTP/2 Framing Layer (Code 16) Heartbeat De-Registration
* **Symptom**: Open5GS AMF and NFs logged `Error in the HTTP2 framing layer (16)` every 11 seconds and de-registered from NRF.
* **Root Cause**: SBI server stanzas lacked container network `advertise: <service_name>` FQDNs, causing NRF to register `0.0.0.0:80` unroutable endpoints.
* **Fix**: Added explicit `advertise: <container_name>` parameters across all 10 `configs/open5gs/*.yaml` configuration files on port `7777`.

### Issue 8.6: Open5GS WebUI Next.js Module Resolution Failure (`modules/store.js`)
* **Symptom**: HTTP 500 error on `http://localhost:9999` with `Module not found: Can't resolve 'modules/store.js' in '/usr/src/app/pages'`.
* **Root Cause**: Open5GS WebUI Next.js server bound to `127.0.0.1` inside container (blocking host port forward) and Webpack lacked `NODE_PATH=src` module resolution paths for `src/` subdirectories (`modules`, `containers`, `components`, `helpers`).
* **Fix**: Added `HOST=0.0.0.0`, `PORT=3000`, and `NODE_PATH=src` in `docker-compose.yml`, and created symlinks pointing `src/*` into `/usr/src/app/node_modules` and `/usr/src/app/pages` in [configs/open5gs/Dockerfile.webui](file:///home/zkhattab/MVNO/configs/open5gs/Dockerfile.webui).

### Issue 8.7: Open5GS WebUI React 15 JSX Transpilation & Node 18 Runtime (`ReferenceError: React is not defined`)
* **Symptom**: HTTP 500 internal server error on `http://localhost:9999` with `ReferenceError: React is not defined` at `Auth.render` or Node ESM syntax errors (`Cannot use import statement outside a module`).
* **Root Cause**: Next.js 3 compiles `pages/` but does not transpile `src/` modules imported via `NODE_PATH=src`. Node 19+ strict ESM loader threw SyntaxError on `import` statements outside modules, and React 15 JSX transpilation required `var React = require('react')` injection.
* **Fix**: Rebased container on official `node:18-bookworm-slim` base image, added Babel 7 CLI + `@babel/preset-env` + `@babel/preset-react` + `@babel/plugin-transform-class-properties` + `@babel/plugin-transform-modules-commonjs` transpilation step in [configs/open5gs/Dockerfile.webui](file:///home/zkhattab/MVNO/configs/open5gs/Dockerfile.webui), and injected `var React = require('react')` to compiled JSX files. Verified `curl http://localhost:9999` returns `HTTP 200 OK` (`<title>Open5gs - Login</title>`).

### Issue 8.8: Open5GS UPF PFCP Client Address Target Resolution (`No Heartbeat from SMF`)
* **Symptom**: System journal reported `[pfcp] WARNING: No Heartbeat from SMF` and `[smf] ERROR: Cannot find PFCP-Node: type [1] node_id NULL from [127.0.0.1]:8805`.
* **Root Cause**: `configs/open5gs/upf.yaml` lacked `pfcp.client.smf` section, defaulting PFCP client heartbeat target to loopback `127.0.0.1:8805` instead of container network hostname `smf`.
* **Fix**: Added `pfcp.client.smf: - address: smf` to [configs/open5gs/upf.yaml](file:///home/zkhattab/MVNO/configs/open5gs/upf.yaml). PFCP heartbeats between SMF and UPF are now associated and healthy across `mvno-net`.
* **Status**: > [!NOTE] Superseded by Issue 8.10 (SMF acts as sole PFCP client initiator per 3GPP TS 29.244).

### Issue 8.9: Open5GS SBI Cleartext HTTP/2 (`no_tls: true`) Configuration Across All NFs
* **Symptom**: Open5GS NRF, AMF, SMF, and AUSF logged `nghttp2_session_mem_recv() failed (-903: Received bad client magic byte string)` and `Error in the HTTP2 framing layer (16)`.
* **Root Cause**: Open5GS SBI server stanzas default to TLS (HTTPS) unless `no_tls: true` is explicitly configured. SBI clients connecting via `http://` failed TLS framing negotiation.
* **Fix**: Added `no_tls: true` under `sbi.server` across all 9 `configs/open5gs/*.yaml` files. All NFs now register successfully with NRF.

### Issue 8.10: Open5GS UPF PFCP State Machine Dual-Initiator Collision
* **Symptom**: SMF & UPF logged `PFCP[REQ] has already been associated` and `invalid step[0] type[6]`.
* **Root Cause**: `configs/open5gs/upf.yaml` erroneously configured `pfcp.client.smf`, causing UPF to initiate PFCP association back to SMF simultaneously, colliding with SMF's PFCP association request.
* **Fix**: Removed `pfcp.client` section from [configs/open5gs/upf.yaml](file:///home/zkhattab/MVNO/configs/open5gs/upf.yaml). SMF acts as sole PFCP client initiator per 3GPP TS 29.244.

### Issue 8.11: EIR SIM-Swap Fraud State Erasure Across Cache Purges
* **Symptom**: Active SIM-swap blocks were bypassed after scheduled 10-minute cache purges or capacity eviction.
* **Root Cause**: `EirTracker.java` evaluated raw call count instead of distinct SIM insertions per IMEI, and called `imeiSwapCounter.clear()`, wiping active fraud states (`swaps > 3`).
* **Fix**: Refactored [EirTracker.java](file:///home/zkhattab/MVNO/telecom-api/src/main/java/com/mvno/intercept/subscriber/EirTracker.java) to track distinct MSISDN bindings (`ConcurrentHashMap<String, Set<String>>`) per IMEI, selectively prune low-activity entries (`removeIf(entry -> entry.getValue().size() <= 1)`), and restrict `reset()` method to test scope.

### Issue 8.12: Split-Brain SQLite Database File Mount (`kamailio` vs `telecom-api`)
* **Symptom**: Kamailio registered subscribers to `./state/kamailio.db` while `telecom-api` read from `./state/kamailio/kamailio.db`, causing subscriber data divergence.
* **Root Cause**: In `docker-compose.yml`, `kamailio` mounted single file `./state/kamailio.db:/etc/kamailio/kamailio.db:z` while `telecom-api` mounted directory `./state/kamailio:/etc/kamailio:z`.
* **Fix**: Unified volume mount in [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml) for `kamailio` service to `./state/kamailio/kamailio.db:/etc/kamailio/kamailio.db:z` and updated [Makefile](file:///home/zkhattab/MVNO/Makefile) `init-db` target.

### Issue 8.13: RTPEngine PCAP vs Audio Recording Method Compatibility with Vosk ASR
* **Symptom**: Native Vosk ASR service polled for audio captures in `/var/spool/rtpengine`, while RTPEngine recorded in binary PCAP format (`recording-method=pcap`).
* **Root Cause**: RTPEngine `mr9.4` supports `recording-method=pcap|proc` and `recording-format=raw|eth` (`fork` is unsupported on this build). Unconditional `Files.deleteIfExists()` in older service builds deleted audio evidence regardless of transcription status.
* **Fix**: Maintained [rtpengine.conf](file:///home/zkhattab/MVNO/configs/rtpengine/rtpengine.conf) baseline `recording-method=pcap` and `recording-format=eth`, restricted [NativeVoskService.java](file:///home/zkhattab/MVNO/telecom-api/src/main/java/com/mvno/intercept/transcription/NativeVoskService.java) `DirectoryStream` filter to audio captures, and implemented evidence archiving to `state/spool/archived/`.

### Issue 8.17: Unauthenticated Intercept REST Endpoints (Zero-Trust Section 1.2)
* **Symptom**: `POST /api/v1/intercept/sms`, `GET /api/v1/intercept/call`, and `POST /api/v1/intercept/call` accepted requests with no credential of any kind, so any reachable client could trigger interception or read subscriber state.
* **Root Cause**: `SubscriberController` and the Kamailio `http_client_query` callout relied on network position (bridge-internal) rather than an application-layer credential.
* **Fix**: Added [ApiKeyInterceptor.java](file:///home/zkhattab/MVNO/telecom-api/src/main/java/com/mvno/intercept/config/ApiKeyInterceptor.java) + [WebConfig.java](file:///home/zkhattab/MVNO/telecom-api/src/main/java/com/mvno/intercept/config/WebConfig.java) (registered on `/api/v1/intercept/**`) with `intercept.api-key: ${X_API_KEY:mvno-demo-key-2026}` in `application.yml`; Kamailio callout switched to 4-arg `http_client_query(url, "", "X-API-Key: ...\r\n", res)` (empty post-data → GET with headers). All consumers keyed: Makefile `make test-api/test-sms/test-call` and runbook steps 4/7/8. `/actuator/*` intentionally left open for vmagent scraping. Verified live: missing/wrong key → `401`; valid key → normal flow; 3 new tests (`ApiKeyInterceptorTest`) → suite now 22/22.

### Issue 8.14: Rootless Podman Docker Socket Path Permission for Vector
* **Symptom**: Vector container failed to collect docker logs with `No such file or directory: /var/run/docker.sock`.
* **Root Cause**: Rootless Podman exposes user-level socket at `/run/user/1000/podman/podman.sock` instead of root system path `/var/run/docker.sock`.
* **Fix**: Updated `vector` volume mount in [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml) to `/run/user/1000/podman/podman.sock:/var/run/docker.sock:ro,z`.

### Issue 8.15: Stale Java Container Tags in `bootstrap.sh`
* **Symptom**: Offline bootstrap save step (`bootstrap.sh --offline`) skipped saving Java image archives.
* **Root Cause**: `SAVE_IMAGES` array in `bootstrap.sh` contained stale `eclipse-temurin:25-jre` tags while `PREBUILT_IMAGES` used Java 21 LTS (`eclipse-temurin:21-jre`).
* **Fix**: Updated `SAVE_IMAGES` array tags in [scripts/bootstrap.sh](file:///home/zkhattab/MVNO/scripts/bootstrap.sh) to `eclipse-temurin-21-jre` and `maven-3.9-eclipse-temurin-21`.

### Issue 8.16: Osmocom VTY Script Container Engine Portability (`vty.sh`)
* **Symptom**: `scripts/vty.sh` hardcoded `podman` engine invocation and relied strictly on container `/dev/tcp` socket redirection.
* **Root Cause**: Non-bash container shells (Alpine/busybox) lack `/dev/tcp` socket redirection syntax, causing execution failure on minimalist images.
* **Fix**: Refactored [scripts/vty.sh](file:///home/zkhattab/MVNO/scripts/vty.sh) with container runtime auto-detection (`podman`/`docker`) and added `nc -w 3 127.0.0.1 <port>` socket redirection fallback.

### Issue 8.18: `docker build` vs `podman build` Store Divergence
* **Symptom**: A fresh `docker build` of the Open5GS container produced a different image than the previously built `podman` image — identical `Dockerfile` and context, different daemon binary md5s and different `imageId`, even though layer hashes appeared equal.
* **Root Cause**: Container engines cache differently (`docker build` separate store; `podman` may reuse a stale local cache) — the "identical layers" hash equality was broken once fresh-archive hashes were compared. This divergence was implicated in the HTTP/2 heartbeat regression hunt (Issue 5.6): the source rebuild experiment was repeated on both engines and only the source-rebuild artifacts (not engine choice) correlated with the framing failures.
* **Fix / Guidance**: Treat the image cache as non-portable across engines. Reproduce experiments on the same engine; do not validate a rebuilt image with a different engine's cache. For Phase 0 the build is frozen: `mvno-open5gs:2.8.0` is layered on the known-good `mvno-open5gs:latest` (a2f041bbd267) with only `iproute2` + `entrypoint.sh` added (Issue 5.6).
* **Verification**: `podman images` shows `mvno-open5gs:latest`/`mvno-open5gs:2.8.0`; daemon binaries inside both images md5-match after the layering fix.

### Issue 8.19: docker-compose IPAM Collision — Unpinned Static IP Grabs Another Service's Address
* **Symptom**: `telecom-api` intermittently came up without its intended static address; a concurrent container (e.g. `mongodb`) had already claimed `10.89.0.4`, and `telecom-api` grabbed a different address (e.g. `10.89.0.46`) — breaking configs that hardcode the gateway's FQDN/address.
* **Root Cause**: `docker-compose.yml` left `telecom-api` `ipv4_address` unpinned at times (or assigned last), while other services used fixed IPs; the bridge IPAM hands out addresses in order, so two services raced for the same subnet slot.
* **Fix**: [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml) pins every service's `ipv4_address` explicitly in a conflict-free plan (e.g. `telecom-api: 10.89.0.46`, `mongodb: 10.89.0.4`), with the plan audited via `podman compose config` (no duplicate IP assertions).
* **Verification**: `podman compose config` exits 0; `podman exec mvno-api ip addr` shows `10.89.0.46/24`; no `Network address already in use` errors across full-stack recreates.

### Issue 8.20: Rootless Podman Has No Host Route to Container IPs — UE↔Bridge Needs UPF-Internal SNAT
* **Symptom**: `sudo ip route add 10.45.0.0/16 via 10.89.0.14` on the host fails with `Error: Nexthop has invalid gateway`; `curl http://10.89.0.46:8080/...` from the host is unreachable even though the container answers on published ports.
* **Root Cause**: Rootless Podman (pasta/slirp) keeps the compose bridge subnet `10.89.0.0/24` inside its **user network namespace** — no host interface carries it, so the host cannot route to container IPs at all. The "host route via the UPF" design (valid for rootful/native deployments) is impossible here; return traffic for anything forwarded out of `ogstun` (10.45.0.0/16) to the bridge would be dropped at the host.
* **Fix**: The UPF entrypoint ([configs/open5gs/entrypoint.sh](file:///home/zkhattab/MVNO/configs/open5gs/entrypoint.sh)) installs an idempotent SNAT rule inside the UPF netns — the whole UE→bridge round-trip stays in-netns:
  ```bash
  iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
  ```
  (`iptables` added to the Open5GS Dockerfile runtime layer; `net.ipv4.ip_forward=1` is already the container default.) Trade-off: bridge services see the UE's traffic with source `10.89.0.14` (the UPF), not the UE's `10.45.0.x`.
* **Verification**: SIP over 5G end-to-end (Phase 1 gate): sim from inside ue-1 with the kamailio `/32` routed via `uesimtun0` → REGISTER 200 OK, INVITE 407 → digest → 100 trying; Kamailio logs show the dialog from `10.89.0.14`; ogstun counters grow (~10 KB RX / ~15 KB TX per dialog pair).

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

### 3. `SipClient` User Agent Interface (A7med3mar4 — `SipClient` Repo)
- **Protocol**: SIP RFC 3261 over UDP.
- **Target Host & Port**: `localhost:5066` on host (maps to `kamailio:5060/udp`).
- **SIP REGISTER Authentication**: Digest authentication (`auth_check()`) using credentials seeded in `kamailio.db`.
- **SIP INVITE Authentication**: `INVITE` is also challenged (`407 Proxy Authentication Required`, zero-trust Section 1.1) — retry with `Authorization: Digest` (realm `localhost`).
- **RTP Media Streams**: RTPEngine UDP port range `30000-30100/udp` (G.711u PCMU codec).
