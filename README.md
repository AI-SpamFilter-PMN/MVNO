# 📡 MVNO Interception & Monitoring Core
### Core Network Interception & Observability for the AI Spam Filter Platform

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose_%7C_Docker-orange?style=for-the-badge&logo=podman)](docs/deployment_guide.md)
[![Database](https://img.shields.io/badge/Database-SQLite_WAL_%7C_MongoDB-green?style=for-the-badge&logo=sqlite)](docs/best_practices.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics_%7C_Grafana-purple?style=for-the-badge&logo=grafana)](docs/best_practices.md)
[![Business](https://img.shields.io/badge/eTOM-Fulfilment_Assurance_Billing-blue?style=for-the-badge)](docs/deployment_guide.md)

This repository contains the **Mobile Virtual Network Operator (MVNO) / Private Mobile Network** core infrastructure simulation. It is designed to act as the traffic interception node and media processing engine for the companion [AI-SpamFilter-PMN/MVNO](https://github.com/AI-SpamFilter-PMN/MVNO) filtration platform.

---

## 🏗️ 1. System Architecture

The core network operates as an unprivileged, rootless stack that handles real-time SMS routing and SIP/VoIP calling, intercepts the payloads, and requests allow/block decisions from the AI Spam Filter REST APIs.

![MVNO Core Integration Flow Diagram](docs/architecture_flow.svg)

---

## ⚙️ 2. Core Functional Transactions

### A. VoIP Voice Call Flow
1. **SIP Invite**: User Equipment 1 (`UE_1`) initiates a call. Kamailio receives the `INVITE` signal.
2. **Media Anchor**: Kamailio hooks `rtpengine` to proxy the media streams in-kernel and forks a raw audio copy into `/var/spool/rtpengine`.
3. **Translation Loop**: When the call completes, the background `vosk_worker.py` detects the finalized `.wav` audio, transcribes it offline via the local Vosk speech-to-text model, and posts the text to the FastAPI Gateway.
4. **AI Interception Check**: FastAPI queries the external **AI Spam Filter REST API**. If flagged as spam, the calling MSISDN is blacklisted.

### B. SMS Interception Flow
1. **SMS Submit**: An ESME client submits an SMS to `OsmoSMSC` via SMPP.
2. **API Verification Check**: `OsmoSMSC` holds delivery and queries the FastAPI gateway (`POST /api/v1/intercept/sms`).
3. **Action Policy**: FastAPI forwards the content to the AI classification model. If approved (`allow: true`), `OsmoSMSC` forwards it to the recipient. If spam, the message is dropped.

---

## 🛠️ 3. Technology Stack

*   **Signaling & Proxy**: Kamailio (SIP Registrar/Proxy) + `rtpengine` (In-kernel media proxy/forker).
*   **SMS Control Plane**: Osmocom (`OsmoSMSC` / `OsmoMSC` / `OsmoHLR`).
*   **Speech Processing**: Vosk Speech-to-Text (Local offline runtime, zero cloud latency).
*   **Interception Gateway**: FastAPI Async ASGI server (Uvicorn).
*   **Observability**: VictoriaMetrics (Single-binary TSDB) + `vmagent` (Telemetry scraper) + Grafana (Dashboard).
*   **Log Mediators**: Vector.dev (Rust-based log pipeline, zero GC).

---

## 🚀 4. Getting Started

### Method A: Containerized (Podman / Docker Compose)
Recommended for sandbox development. Rootless-compliant out-of-the-box (no system modifications needed).

1. **Deploy the stack**:
   ```bash
   make up
   ```
2. **Review running containers**:
   ```bash
   podman ps
   ```
3. **Trigger mock SMS traffic to verify interception**:
   ```bash
   make test-sms
   ```
4. **Trigger mock SIP VoIP call to verify media recording**:
   ```bash
   make test-call
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

## 📖 5. Documentation Directory

All architectural plans, setup guides, and best practices are stored locally inside the repository:
*   [docs/implementation_plan.md](docs/implementation_plan.md): Contains system requirements, open design questions, and verification scenarios.
*   [docs/deployment_guide.md](docs/deployment_guide.md): Details the step-by-step configuration runbook, ports, and configuration scripts for Kamailio, rtpengine, and Osmocom.
*   [docs/best_practices.md](docs/best_practices.md): Lists advanced telecom security practices, including PIKE rate limiting, Caller ID spoofing prevention (STIR/SHAKEN), WebRTC transcoding, and SQLite WAL tuning.
*   [.agents/AGENTS.md](.agents/AGENTS.md): Preserves project-scoped constraints for lightweight memory footprints.