# MVNO Interception & Monitoring Core
### Core Network Interception & Observability for the AI Spam Filter Platform

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose_%7C_Docker-orange?style=for-the-badge&logo=podman)](docs/deployment_guide.md)
[![Database](https://img.shields.io/badge/Database-SQLite_WAL_%7C_MongoDB-green?style=for-the-badge&logo=sqlite)](docs/deployment_guide.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics_%7C_Grafana-purple?style=for-the-badge&logo=grafana)](docs/deployment_guide.md)

Simulates an MVNO / Private Mobile Network core for the companion [AI Spam Filter](https://github.com/AI-SpamFilter-PMN/AI-Filteration-System) platform. Handles SMS routing and SIP/VoIP calling, intercepts payloads in real-time, and enforces allow/block decisions from the AI filter REST API.

---

## 1. System Architecture

The core network operates as an unprivileged, rootless stack that handles real-time SMS routing and SIP/VoIP calling, intercepts the payloads, and requests allow/block decisions from the AI Spam Filter REST APIs.

[![MVNO Core Integration Flow Diagram](docs/architecture_flow.png)](docs/architecture_flow.svg)

```
SIP Phone ──▶ Kamailio ──▶ rtpengine ──(Audio Spool)──┐
                │            (RTP Engine)             ▼
SMPP Client ──▶ OsmoSMSC ───────────────▶ Spring Boot Gateway (Java 21) ──▶ AI Spam Filter
                │ 2G SMSC        ┌─────── (Native Vosk ASR JNI)
5G UE ──▶ Open5GS (AMF) ───────▶│
2G MS ──▶ 2G Core (BSC/BTS) ──▶ OsmoSMSC ──▶ IP-SM-GW ──▶ Kamailio ──▶ 5G UE   (2G↔5G SMS)
```

Two interception flows — SMS (via OsmoSMSC SMPP) and Voice (via Kamailio SIP). The 5G SA core adds UERANSIM gNB+UE simulation with live PDU Session establishment (`S-NSSAI {sst: 1, sd: 0x000001}`) and IPv4 data-plane allocation (`10.45.0.0/16`). All decisions go through the Spring Boot policy gateway.

A **TS 23.204 IP-SM-GW bridge** (`mvno-ip-sm-gw`) provides 2G↔5G SMS interworking: it polls the 2G SMSC store-and-forward DB (`smsc.db`) and relays stored SMS toward 5G/IMS subscribers as SIP `MESSAGE` into Kamailio, and in the reverse direction receives 5G SMS on SIP port `5090` and backhauls them to the SMSC via SMPP `submit_sm`.

Test subscribers: **5G UEs** — **UE-1** (15551234567, balance=100), **UE-2** (15557654321, balance=0), **UE-3** (15559998888, balance=100). **2G MSs** (OsmocomBB, virtual radio) — **2G-MS** (15554443322), **2G-MS2** (15557778888), SMSC short-code `15550000000`. EIR SIM-swap fraud detection triggers dynamically on multi-SIM IMEI bindings.

---

## 2. Core Functional Transactions

### A. VoIP Voice Call Interception
[![IMS Voice Call Interception Flow](docs/ims_voice_call_flow.png)](docs/ims_voice_call_flow.svg)

1. UE_1 sends a `SIP INVITE`. Kamailio checks prepaid balance and EIR via the Spring Boot gateway.
2. If allowed, Kamailio anchors media through `rtpengine` (userspace mode) and forks a WAV copy to `/var/spool/rtpengine`.
3. After the call, `NativeVoskService.java` transcribes the audio offline via Vosk Java 21 JNI and sends the result to the AI filter.
4. If flagged by policy checks, the gateway returns `allow: false` with an explicit rejection reason.

### B. SMS Interception
[![SMS Interception Flow](docs/sms_interception_flow.png)](docs/sms_interception_flow.svg)

1. ESME submits SMS to `OsmoSMSC` via SMPP 3.4.
2. OsmoSMSC holds delivery and calls `POST /api/v1/intercept/sms` on the Spring Boot gateway.
3. Gateway checks prepaid balance, then forwards content to the AI filter. `allow: true` → delivered. `allow: false` → dropped.

---

## 3. Technology Stack

- **Signaling & Proxy**: Kamailio (SIP Registrar/Proxy) + `rtpengine` (Userspace media proxy/forker).
- **SMS Control Plane**: Osmocom (`OsmoSMSC` + `OsmoHLR`).
- **Speech Processing**: Native Vosk Speech-to-Text (In-JVM JNI Java 21 runtime, zero cloud latency).
- **Interception Gateway**: Spring Boot 3.4.3 + Java 21 LTS + Virtual Threads (Tomcat, JdbcTemplate, RestClient).
- **Observability**: VictoriaMetrics (Single-binary TSDB) + `vmagent` (Telemetry scraper) + Grafana (Dashboard).
- **Log Mediators**: Vector.dev (Rust-based log pipeline, zero GC).
- **5G Core**: Open5GS (10 NFs) + UERANSIM (gNB + 3 UEs).

---

## 4. Getting Started

### Method A: Containerized (Podman / Docker Compose)
Recommended for sandbox development. Rootless-compliant out-of-the-box.

```bash
# 1. Prerequisites (pick your distro — SCTP kernel module required for 5G NGAP)
sudo apt install -y podman docker-compose-v2 sqlite3 lksctp-tools  # Debian/Ubuntu
sudo dnf install -y podman podman-compose sqlite3 lksctp-tools        # Fedora/RHEL
sudo pacman -S --needed podman docker-compose sqlite3                # Arch/CachyOS
sudo modprobe sctp                                                    # Load SCTP kernel module

# 2. Enable Podman API socket (required for Docker Compose Plugin)
systemctl --user enable --now podman.socket

# 3. Initialize SQLite databases (WAL mode + test subscribers)
make init-db

# 4. Start the stack — offline-first (uses pre-loaded images)
make up

#    To build from source instead (needs internet):
#    podman compose -f docker-compose.yml -f docker-compose.build.yml up -d --build

# 5. Smoke-test the stack (after containers are up)
curl http://localhost:8080/actuator/health/liveness
# Expected: {"status":"UP"}

curl -H "X-API-Key: mvno-demo-key-2026" http://localhost:8080/api/v1/intercept/subscriber/15551234567
# Expected: {"msisdn":"15551234567","balance":100}  ← allowed

curl -H "X-API-Key: mvno-demo-key-2026" http://localhost:8080/api/v1/intercept/subscriber/15557654321
# Expected: {"msisdn":"15557654321","balance":0}    ← zero-balance blocked

# 6. Test interception & execute automated presentation runbook
make test-sms    # HTTP SMS policy intercept endpoint verification
make test-call   # HTTP voice call policy intercept endpoint verification (EIR & balance)
./scripts/testing/demo_runbook.sh  # Complete 13-step graduation project live presentation
```

### Method B: Native (systemd)
Deploying directly onto a Debian/Ubuntu 22.04 LTS host:

1. **Install dependencies**:
   ```bash
   sudo apt install kamailio kamailio-sqlite-modules ngcp-rtpengine osmo-msc osmo-hlr
   ```
2. **Initialize SQLite databases** (experimental):
   ```bash
   make init-native-db
   ```
3. **Start the systemd services** (experimental):
   ```bash
   make up-native
   ```

---

## 5. Network Ports & Protocols

| Service | Container Name | Port | Protocol | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Spring Boot Gateway** | `mvno-api` | `8080` | HTTP / REST | Interception policy control & subscriber API |
| **Kamailio CSCF** | `mvno-kamailio` | `5066 (host) → 5060` | UDP / TCP | SIP signaling & registrar proxy |
| **rtpengine NG** | `mvno-rtpengine` | `22222 (internal)` | UDP | Userspace media proxy control port |
| **rtpengine Media** | `mvno-rtpengine` | `30000-30100`| UDP | RTP media audio stream relay range |
| **OsmoSMSC + OsmoHLR** | `mvno-osmosmsc` | `2775` | TCP / SMPP | Short Message Peer-to-Peer (SMPP 3.4) |
| **OsmoHLR** | `mvno-osmo-hlr` | `4222 (internal)` | TCP / GSUP | Standalone subscriber location database |
| **IP-SM-GW Bridge** | `mvno-ip-sm-gw` | `5090 (SIP)` + `2775 (SMPP)` | UDP / SMPP | TS 23.204 2G SMSC ↔ 5G/IMS SMS interworking bridge |
| **VictoriaMetrics** | `mvno-victoriametrics`| `8428` | HTTP | Telemetry TSDB & PromQL query API |
| **vmagent Scraper** | `mvno-vmagent` | `8429` | HTTP | Telemetry scraper target health API |
| **Grafana NOC** | `mvno-grafana` | `3000` | HTTP | Real-time telecom NOC dashboard UI |
| **Open5GS WebUI** | `mvno-open5gs-webui`| `9999` | HTTP | Subscriber SIM & Profile Management UI |
| **AI Spam Model** | `ai-filter` | `8008 (host) → 8000` | HTTP / REST | External AI Spam Model Server (mock) |

---

## 6. Features

| # | Feature | How |
|---|---------|-----|
| 1 | **Prepaid OCS** | SQLite balance check before every call/SMS. Zero-balance → blocked. |
| 2 | **Caller-ID Auth** | Kamailio digest authentication for REGISTER + INVITE (407 challenge live). |
| 3 | **LAC/CellID Geofencing** | Cell ID parsing and zone-based geofencing policy (Mock / Roadmap item). |
| 4 | **EIR SIM-Swap Detection** | In-memory IMEI→MSISDN tracker. >3 distinct SIMs per IMEI → blocked. |
| 5 | **DTMF Telemetry** | rtpengine captures DTMF events (`dtmf-log=yes`); REST biometrics payload accepted by gateway. |
| 6 | **Voice Biometrics** | Silence ratio and spectral flatness biometrics payload schema (Mock / Roadmap item). |
| 7 | **SLA Fallback** | Spring Boot gateway fallback (`allow: true`) when AI filter is unreachable/times out. |
| 8 | **5G SA Core** | Open5GS 10-NF 5GC + UERANSIM gNB + 3 UE simulation with live PDU Session establishment (`10.45.0.0/16`). |
| 9 | **SMS-over-NAS** | 5G NAS SMS routing architecture contract (Mock / Roadmap item). |
| 10 | **MongoDB Seed** | Atomic init script (`scripts/seed-mongo.sh`) provisions 3 UEs into `open5gs.subscribers` avoiding WebUI admin hash bug. |
| 11 | **IP-SM-GW 2G↔5G SMS Bridge** | TS 23.204 interworking bridge (`mvno-ip-sm-gw`): polls 2G SMSC store-and-forward DB and relays to 5G/IMS via SIP MESSAGE; backhauls 5G SMS to SMSC via SMPP submit_sm. Both legs verified end-to-end. |

---

## 7. Documentation

* [ONBOARDING.md](ONBOARDING.md): Team onboarding guide, setup instructions, make targets, and Section 14 integration specs.
* [docs/MANUAL_TESTING_GUIDE.md](docs/MANUAL_TESTING_GUIDE.md): Full multi-terminal manual testing guide — all MVP flows (2G/5G SMS, 2G↔5G IP-SM-GW bridging, SIP/IMS calls, RTP engine media, Vosk STT, recording, interception REST API, Grafana/VictoriaMetrics telemetry).
* [docs/API_CONTRACT.md](docs/API_CONTRACT.md): Public AI Spam Filter REST API contract & JSON schemas for teammates.
* [docs/deployment_guide.md](docs/deployment_guide.md): Deployment runbook — ports, configs, commands, troubleshooting. Primary team reference.
* [docs/ROADMAP.md](docs/ROADMAP.md): Architectural roadmap and operational backlog (SIP 407 + API keys implemented; VictoriaLogs, healthchecks, SBI eval open).
* [docs/ISSUES.md](docs/ISSUES.md): Root cause analysis log and Section 10 Cross-Repo Contract Specifications.
* [docs/architecture_flow.svg](docs/architecture_flow.svg): System architecture overview diagram.
* [docs/ims_voice_call_flow.svg](docs/ims_voice_call_flow.svg): IMS VoLTE/VoNR Voice Call Interception sequence diagram.
* [docs/sms_interception_flow.svg](docs/sms_interception_flow.svg): SMS Store-and-Forward Interception sequence diagram.

### Key Environment Variable

| Variable | Default | Purpose |
|---|---|---|
| `AI_FILTER_URL` | `http://ai-filter:8000/api/v1/classify` | External AI Spam Model REST endpoint — set in `docker-compose.yml` environment block |