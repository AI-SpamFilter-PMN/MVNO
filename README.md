# MVNO Interception & Monitoring Core

Rootless containerized MVNO core network with 5G SA, SMS/VoIP interception, offline STT, and AI spam filtration.

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose-orange?style=for-the-badge&logo=podman)](docs/implementation_guide.md)
[![5G Core](https://img.shields.io/badge/5G%20SA-Open5GS%20%7C%20UERANSIM-blue?style=for-the-badge)](docs/implementation_guide.md#13-5g-sa-integration)
[![Database](https://img.shields.io/badge/Database-SQLite%20WAL%20%7C%20MongoDB-green?style=for-the-badge)](docs/implementation_guide.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics%20%7C%20Grafana-purple?style=for-the-badge&logo=grafana)](docs/implementation_guide.md)
[![eTOM](https://img.shields.io/badge/eTOM-Fulfilment%20Assurance%20Billing-blue?style=for-the-badge)](docs/implementation_guide.md#2-architecture-overview)
[![OS](https://img.shields.io/badge/OS-CachyOS%20%7C%20Arch%20%7C%20Debian%20%7C%20Fedora-lightgrey?style=for-the-badge)](docs/implementation_guide.md#3-prerequisites)

---

## Architecture

```
SIP Phone ──▶ Kamailio ──▶ rtpengine ──▶ Vosk STT
                │                          │
SMPP Client ──▶ OsmoSMSC ──▶ FastAPI Gateway ──▶ AI Spam Filter
                │              │
5G UE ──▶ Open5GS (AMF) ──┘   └── MongoDB (subscribers)
```

Two interception flows — SMS (via OsmoSMSC SMPP) and Voice (via Kamailio SIP). The 5G SA core adds UERANSIM gNB+UE simulation with SMS-over-NAS routed through the same pipeline. All decisions go through the FastAPI policy gateway.

3 test UEs: **normal** (balance=100), **spam** (EIR trigger), **zero-balance** (OCS block).

---

## Quick Start

```bash
# 1. Prerequisites (pick your distro)
sudo pacman -S --needed podman podman-compose python python-pip sqlite3   # Arch/CachyOS
sudo apt install -y podman podman-compose python3 python3-pip sqlite3     # Debian/Ubuntu
sudo dnf install -y podman podman-compose python3 python3-pip sqlite3     # Fedora

# 2. Initialize databases
make init-db

# 3. Start the stack (9 containers, ~15 with 5G SA)
make up

# 4. Test interception
make test-sms    # SMS via SMPP → FastAPI → AI Filter
make test-call   # SIP call → rtpengine → Vosk STT → FastAPI
```

---

## Stack

| Layer | Components | Purpose |
|-------|-----------|---------|
| **5G Access** | UERANSIM (gNB + 3 UEs) | 5G SA simulation over N2/N3 |
| **5G Core** | Open5GS (NRF, AMF, SMF, UPF, UDM, AUSF, NSSF, PCF, UDR, BSF) | 5GC network functions + MongoDB subscriber DB |
| **MVNO Core** | Kamailio, rtpengine, OsmoSMSC | SIP routing, media anchoring, SMS store-and-forward |
| **Interception** | FastAPI Gateway, Vosk STT | AI filter decision point, offline speech-to-text |
| **Observability** | VictoriaMetrics, Grafana, Vector | Metrics, dashboards, log shipping |

---

## Features

| # | Feature | Implementation |
|---|---------|---------------|
| 1 | **Prepaid OCS** | Balance check before calls/SMS. Zero-balance blocked. |
| 2 | **STIR/SHAKEN** | SIP `From` header vs authenticated user. Spoof → 407. |
| 3 | **Geofencing** | LAC/CellID from OsmoSMSC logs → zone-based AI filtering. |
| 4 | **EIR Binding** | IMEI-IMSI tracking. Rapid SIM swaps blocked. |
| 5 | **DTMF Logging** | rtpengine tones captured in JSON metadata. |
| 6 | **Voice Biometrics** | Silence ratio + spectral flatness for robocall/TTS detection. |
| 7 | **SLA Fallback** | Local HTable whitelist/blacklist when AI filter is down. |
| 8 | **5G SA Core** | Open5GS 10-NF 5GC + UERANSIM simulation. |
| 9 | **SMS-over-NAS** | 5G UE → AMF → OsmoSMSC → FastAPI (same pipeline). |
| 10 | **MongoDB Seed** | Atomic init script avoids WebUI `admin/1423` hash bug. |

---

## Documentation

| Document | Covers |
|----------|--------|
| [implementation_guide.md](docs/implementation_guide.md) | Full 1876-line guide: critical thinking methodology, all configs, code, troubleshooting, 5G SA |
| [deployment_guide.md](docs/deployment_guide.md) | Original apt-based deployment runbook |
| [best_practices.md](docs/best_practices.md) | SOTA architectural decisions |
