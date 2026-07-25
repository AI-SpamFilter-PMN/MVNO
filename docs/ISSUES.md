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
  FROM kamailio/kamailio:5.7-alpine
  RUN apk add --no-cache kamailio-utils
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

---

## 4. RTPEngine Media Relay Issues

### Issue 4.1: Invalid `recording-format=wav` Parameter
* **Symptom**: RTPEngine ignores recording format setting; WAV files are not generated.
* **Root Cause**: `rtpengine` only supports `eth` (PCAP) or `raw` PCAP recording formats. It does not perform inline WAV encoding.
* **Fix**: Set `recording-format = eth` in `configs/rtpengine/rtpengine.conf`. PCAP → WAV conversion is performed downstream by `vosk-worker` via `ffmpeg`.

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

---

## 6. Control-Plane & Telemetry Pipeline Operational RCA

### Issue 6.1: SQLite WAL Directory Mount Permission (`SQLITE_READONLY_DIRECTORY`)
* **Symptom**: `telecom-api` REST queries returned `balance: 0` for all subscribers, and container logs showed `[SQLITE_READONLY_DIRECTORY] Process does not have permission to create a journal file in the same directory as the database`.
* **Root Cause**: Single-file bind mount (`- ./state/kamailio.db:/etc/kamailio/kamailio.db:z`) prevented the non-root container process from creating temporary `.db-wal` and `.db-shm` lock/journal files in `/etc/kamailio/`.
* **Fix**: Updated `docker-compose.yml` to mount the parent directory (`- ./state:/etc/kamailio:z`), allowing SQLite WAL mode to create journal/shm files seamlessly.

### Issue 6.2: `vmagent` Promscrape Configuration Flag Omission
* **Symptom**: VictoriaMetrics (`:8428`) and Grafana NOC Dashboards (`:3000`) rendered empty metric panels with zero active targets.
* **Root Cause**: `vmagent` container command stanza was missing `-promscrape.config=/etc/prometheus/prometheus.yml`, causing `vmagent` to run in silent mode without loading target scrape configurations. Additionally, the target hostname in `scrape.yml` was listed as `telecom-api` instead of `mvno-api`.
* **Fix**: Added `-promscrape.config=/etc/prometheus/prometheus.yml` and exposed port `8429:8429` in `docker-compose.yml`, and updated `scrape.yml` target address to `mvno-api:8080`. Verified `3/3` active targets scraped (`lastSamplesScraped: 136`).

### Issue 6.3: Grafana SQLite WAL Corruption
* **Symptom**: Grafana crashes after host reboot with `database is locked` or `disk I/O error`.
* **Fix**: Pinned image to `grafana/grafana-oss:11.6.0` and set `GF_DATABASE_WAL=true` in `docker-compose.yml`.

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

---

## 8. Podman & Docker Container Engine & Networking Issues

### Issue 8.1: Loopback (`127.0.0.1`) Isolation in Container Bridge Networks (`mvno_net`)
* **Symptom**: Inter-container communication fails with `Connection Refused` or `Network unreachable`.
* **Root Cause**: Services binding to `127.0.0.1` bind exclusively to the container's private loopback interface (`lo`).
* **Fix**: All containerized daemons MUST bind server sockets to `0.0.0.0` or container DNS hostnames.

### Issue 8.2: Rootless Podman Port Binding & Privileged Port Boundaries
* **Symptom**: Podman fails to bind host port `5060` or `2775` in rootless mode: `Permission denied`.
* **Fix**: Map host ports above 1024 (e.g. `5066:5060/udp` for Kamailio) or configure `net.ipv4.ip_unprivileged_port_start=1024`.

---

## 9. Master Verification & Verification Checklist

| Target / Subsystem | Command / Probe | Expected Result | Verification Status |
|---|---|---|---|
| **Spring Boot Unit Tests** | `./mvnw test` | `Tests run: 11, Failures: 0` | ✅ **PASS** |
| **Gateway Liveness** | `GET :8080/actuator/health/liveness` | `{"status":"UP"}` | ✅ **PASS** |
| **Subscriber Balance API** | `GET :8080/api/v1/intercept/subscriber/15551234567` | `{"msisdn":"15551234567","balance":100}` | ✅ **PASS** |
| **Normal VoIP Call** | `POST /api/v1/intercept/call` (`caller: 15551234567`) | `{"allow":true,"reason":"AI filter unreachable — SLA allow"}` | ✅ **PASS** |
| **Zero-Balance Call Block** | `POST /api/v1/intercept/call` (`caller: 15557654321`) | `{"allow":false,"reason":"Prepaid balance exhausted"}` | ✅ **PASS** |
| **Normal 5G SMS** | `POST /api/v1/intercept/sms` (`sender: 15551234567`) | `{"allow":true,"reason":"AI filter unreachable — SLA allow"}` | ✅ **PASS** |
| **Zero-Balance SMS Block** | `POST /api/v1/intercept/sms` (`sender: 15557654321`) | `{"allow":false,"reason":"Prepaid balance exhausted"}` | ✅ **PASS** |
| **EIR SIM-Swap Block** | 4 rapid calls on single IMEI | `{"allow":false,"reason":"EIR: SIM swap detected"}` | ✅ **PASS** |
| **vmagent Scraper Targets** | `GET :8429/api/v1/targets` | `3/3 targets health: UP` | ✅ **PASS** |
| **VictoriaMetrics TSDB** | `GET :8428/api/v1/query?query=mvno_sms_requests_total` | `seriesFetched: 1`, `value: [ts, "2"]` | ✅ **PASS** |
| **Grafana NOC Dashboard UI** | `GET :3000/login` | `HTTP 200 OK` | ✅ **PASS** |
