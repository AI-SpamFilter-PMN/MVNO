# MVNO Interception & Monitoring Core
### Core Network Interception & Observability for the AI Spam Filter Platform

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose_%7C_Docker-orange?style=for-the-badge&logo=podman)](docs/deployment_guide.md)
[![Database](https://img.shields.io/badge/Database-SQLite_WAL_%7C_MongoDB-green?style=for-the-badge&logo=sqlite)](docs/deployment_guide.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics_%7C_Grafana-purple?style=for-the-badge&logo=grafana)](docs/deployment_guide.md)
[![Business](https://img.shields.io/badge/eTOM-Fulfilment_Assurance_Billing-blue?style=for-the-badge)](docs/deployment_guide.md)

This repository contains the **Mobile Virtual Network Operator (MVNO) / Private Mobile Network** core infrastructure simulation. It is designed to act as the traffic interception node and media processing engine for the companion [AI-SpamFilter-PMN/MVNO](https://github.com/AI-SpamFilter-PMN/MVNO) filtration platform.

---

## 1. System Architecture

The core network operates as an unprivileged, rootless stack that handles real-time SMS routing and SIP/VoIP calling, intercepts the payloads, and requests allow/block decisions from the AI Spam Filter REST APIs.

![MVNO Core Integration Flow Diagram](docs/architecture_flow.svg)

```
SIP Phone ──▶ Kamailio ──▶ rtpengine ──▶ Vosk STT
                │
SMPP Client ──▶ OsmoSMSC ──▶ Spring Boot Gateway ──▶ AI Spam Filter
                │                         │
5G UE ──▶ Open5GS (AMF) ──┘              └── MongoDB (subscribers)
```

Two interception flows — SMS (via OsmoSMSC SMPP) and Voice (via Kamailio SIP). The 5G SA core adds UERANSIM gNB+UE simulation with SMS-over-NAS routed through the same pipeline. All decisions go through the Spring Boot policy gateway.

3 test UEs: **normal** (balance=100), **spam** (EIR trigger), **zero-balance** (OCS block).

---

## 2. Core Functional Transactions

### A. VoIP Voice Call Flow
1. **SIP Invite**: User Equipment 1 (`UE_1`) initiates a call. Kamailio receives the `INVITE` signal.
2. **Media Anchor**: Kamailio hooks `rtpengine` to proxy the media streams in-kernel and forks a raw audio copy into `/var/spool/rtpengine`.
3. **Translation Loop**: When the call completes, the background `vosk_worker.py` detects the finalized `.wav` audio, transcribes it offline via the local Vosk speech-to-text model, and posts the text to the Spring Boot Gateway.
4. **AI Interception Check**: Spring Boot queries the external **AI Spam Filter REST API**. If flagged as spam, the calling MSISDN is blacklisted.

### B. SMS Interception Flow
1. **SMS Submit**: An ESME client submits an SMS to `OsmoSMSC` via SMPP.
2. **API Verification Check**: `OsmoSMSC` holds delivery and queries the Spring Boot gateway (`POST /api/v1/intercept/sms`).
3. **Action Policy**: Spring Boot forwards the content to the AI classification model. If approved (`allow: true`), `OsmoSMSC` forwards it to the recipient. If spam, the message is dropped.

---

## 3. Technology Stack

- **Signaling & Proxy**: Kamailio (SIP Registrar/Proxy) + `rtpengine` (In-kernel media proxy/forker).
- **SMS Control Plane**: Osmocom (`OsmoSMSC` / `OsmoMSC` / `OsmoHLR`).
- **Speech Processing**: Vosk Speech-to-Text (Local offline runtime, zero cloud latency).
- **Interception Gateway**: Spring Boot 4.1 + JDK 25 + Virtual Threads (Tomcat, JDBCTemplate, RestClient).
- **Observability**: VictoriaMetrics (Single-binary TSDB) + `vmagent` (Telemetry scraper) + Grafana (Dashboard).
- **Log Mediators**: Vector.dev (Rust-based log pipeline, zero GC).
- **5G Core**: Open5GS (10 NFs) + UERANSIM (gNB + 3 UEs).

---

## 4. Getting Started

### Method A: Containerized (Podman / Docker Compose)
Recommended for sandbox development. Rootless-compliant out-of-the-box.

```bash
# 1. Prerequisites (pick your distro)
sudo pacman -S --needed podman docker-compose python python-pip sqlite3   # Arch/CachyOS
sudo apt install -y podman docker-compose python3 python3-pip sqlite3     # Debian/Ubuntu
sudo dnf install -y podman docker-compose python3 python3-pip sqlite3     # Fedora

# 2. Enable Podman API socket (required for Docker Compose Plugin)
systemctl --user enable --now podman.socket

# 3. Initialize databases
make init-db

# 4. Start the stack — offline-first (uses pre-loaded images)
make up

#    To build from source instead (needs internet):
#    podman compose -f docker-compose.yml -f docker-compose.build.yml up -d --build

# 5. Test interception
make test-sms    # SMS via SMPP → Spring Boot → AI Filter
make test-call   # SIP call → rtpengine → Vosk STT → Spring Boot
```

### Method B: Native (systemd)
Deploying directly onto a Debian/Ubuntu 22.04 LTS host:

1. **Install dependencies**:
   ```bash
   sudo apt install kamailio kamailio-sqlite-modules ngcp-rtpengine osmo-msc osmo-hlr
   ```
2. **Initialize SQLite databases**:
   ```bash
   make init-native-db
   ```
3. **Start the systemd services**:
   ```bash
   make up-native
   ```

---

## 5. Stack

| Layer | Components | Purpose |
|-------|-----------|---------|
| **5G Access** | UERANSIM (gNB + 3 UEs) | 5G SA simulation over N2/N3 |
| **5G Core** | Open5GS (NRF, AMF, SMF, UPF, UDM, AUSF, NSSF, PCF, UDR, BSF) | 5GC network functions + MongoDB subscriber DB |
| **MVNO Core** | Kamailio, rtpengine, OsmoSMSC | SIP routing, media anchoring, SMS store-and-forward |
| **Interception** | Spring Boot Gateway, Vosk STT | AI filter decision point, offline speech-to-text |
| **Observability** | VictoriaMetrics, Grafana, Vector | Metrics, dashboards, log shipping |

---

## 6. Features

| # | Feature | Implementation |
|---|---------|---------------|
| 1 | **Prepaid OCS** | Balance check before calls/SMS. Zero-balance blocked. |
| 2 | **STIR/SHAKEN** | SIP `From` header vs authenticated user. Spoof blocked. |
| 3 | **Geofencing** | LAC/CellID from OsmoSMSC logs → zone-based AI filtering. |
| 4 | **EIR Binding** | IMEI-IMSI tracked in Spring Boot gateway. Rapid SIM swaps blocked. |
| 5 | **DTMF Logging** | rtpengine tones captured in JSON metadata. |
| 6 | **Voice Biometrics** | Silence ratio + spectral flatness for robocall/TTS detection. |
| 7 | **SLA Fallback** | Local HTable whitelist/blacklist when AI filter is down. |
| 8 | **5G SA Core** | Open5GS 10-NF 5GC + UERANSIM simulation. |
| 9 | **SMS-over-NAS** | 5G UE → AMF → OsmoSMSC → Spring Boot Gateway (same pipeline). |
| 10 | **MongoDB Seed** | Atomic init script avoids WebUI admin hash bug. |

---

## 7. Documentation

* [docs/deployment_guide.md](docs/deployment_guide.md): Deployment runbook — ports, configs, commands, troubleshooting. Primary team reference.
* [docs/architecture_flow.svg](docs/architecture_flow.svg): System architecture diagram.