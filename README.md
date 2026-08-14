# MVNO Interception & Monitoring Core
### Core Network Interception & Observability for the AI Spam Filter Platform

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose_%7C_Docker-orange?style=for-the-badge&logo=podman)](docs/deployment_guide.md)
[![Database](https://img.shields.io/badge/Database-SQLite_WAL_%7C_MongoDB-green?style=for-the-badge&logo=sqlite)](docs/deployment_guide.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics_%7C_Grafana-purple?style=for-the-badge&logo=grafana)](docs/deployment_guide.md)
[![SMS Interworking](https://img.shields.io/badge/2G%E2%86%945G_SMS-IP--SM--GW_%7C_Kamailio-blue?style=for-the-badge)](docs/implementation_guide.md)
[![AI Block](https://img.shields.io/badge/AI_Spam_Block-Deterministic_E2E--BLOCK-red?style=for-the-badge)](docs/LIVE_DEMO.md)
[![Media Server](https://img.shields.io/badge/Media_Server-Asterisk_20.6_ConfBridge-blueviolet?style=for-the-badge)](docs/ARCHITECTURE_DECISIONS.md)

Simulates an MVNO / Private Mobile Network core for the companion [AI Spam Filter](https://github.com/AI-SpamFilter-PMN/AI-Filteration-System) platform (and its `Filteration-System` voice decider). Handles cellular SMS routing, SIP/IMS voice calling, multi-party conference mixing, and real-time payload interception, enforcing allow/block decisions from the AI filter REST APIs (`/api/v1/classify` for call/SMS/transcript, `filteration-system:8000/api/v1/voice/filter` for post-call voice decider).

---

## 1. System Architecture

The core network operates as an unprivileged, rootless stack composed of **37 orchestrated containers** across 4 functional domains:

[![MVNO Core Integration Flow Diagram](docs/architecture_flow.png)](docs/architecture_flow.svg)

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   MVNO CORE ARCHITECTURE TOPOLOGY                                │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                  │
│  [Physical Phone / SIP UA] ──▶ Kamailio (Edge Proxy :5060) ──▶ RTPEngine (Media Relay)           │
│                                    │                                  │ (Audio Forking)          │
│                                    ├──▶ Asterisk 20.6 (:5061)        ▼                           │
│                                    │    (ConfBridge 7XXX, IVR 8000)  Spring Boot Gateway (:8080) │
│                                    │                                 (Native Vosk ASR JNI)       │
│                                    ▼                                          │                  │
│  [5G SA Radio (UERANSIM)]  ──▶ Open5GS 5GC (10 NFs)                           ▼                  │
│                                    │                                  AI Spam Filter (:8000)     │
│                                    ▼                                  (allow / block decision)   │
│  [2G GSM MS (OsmocomBB)]   ──▶ OsmoSMSC (:2775) ──▶ IP-SM-GW (:5090) ────────┘                  │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Key Architectural Layers:
1. **Signaling & Edge Proxy**: **Kamailio 5.7** handles SIP registrations (digest-challenged), policy routing, international MSISDN prefix normalization, and SMS payload parsing.
2. **Media Plane & Transcoding**: **RTPEngine NG** provides userspace RTP media relaying and call recording forking. **Asterisk 20.6** acts as an MCU sidecar providing audio mixing for **ConfBridge `7XXX` / RFC 4579 `conf-factory`**, **In-Call Audio Whisper Warnings**, **Interactive Call Screening `8000`**, and **Voicemail `8XXX`**.
3. **Hardware Audio Integration**: Host-native **PipeWire / PulseAudio** integration provides real-time, full-duplex hardware microphone capture and speaker output across both softphone endpoints without file-based intermediary buffering.
4. **SMS Interworking & Control**: Osmocom (`OsmoSMSC` + `OsmoHLR`) provides GSM 03.40 store-and-forward SMSC capabilities. A **TS 23.204 IP-SM-GW bridge** (`mvno-ip-sm-gw`) bi-directionally bridges 2G SMPP messages with 5G/IMS SIP `MESSAGE` transactions.
5. **AI Interception & Policy Core**: **Spring Boot 3.4.3** (Java 21 LTS, Virtual Threads, SQLite WAL OCS balance check, EIR SIM-swap fraud protection, and in-JVM native **Vosk ASR JNI** for sub-2.0s real-time speech-to-text).
6. **5G Standalone (SA) Core**: **Open5GS** (10 NFs: NRF, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) + **UERANSIM** (gNB + 3 UEs) with S-NSSAI Network Slicing (`SST=1` eMBB vs `SST=2` URLLC).
7. **Unified 5-Repository Multi-Compose Stack**: Master orchestration linking `MVNO`, `Filteration-System`, `admin-client`, `sms-client`, and `SipClient` on a single container network (`make all-up`).

---

## 2. Core Functional Transactions

### A. VoIP Voice Call, Conferencing & Whisper Warning
[![IMS Voice Call Interception Flow](docs/ims_voice_call_flow.png)](docs/ims_voice_call_flow.svg)

1. **Pre-Call Policy Gate**: Caller sends `SIP INVITE`. Kamailio invokes `telecom-api:8080/api/v1/intercept/call` to verify prepaid balance (>0) and check EIR IMEI SIM-swap thresholds.
2. **Media Anchoring**: Upon `200 OK`, Kamailio anchors RTP media through RTPEngine and mirrors a dual-leg stream to `/var/spool/rtpengine/`.
3. **Advanced Telephony & Media Features**:
   * **3GPP RFC 4579 Multi-Party Conference**: Android Linphone "Merge Calls" or dialing `7001` / `*7` merges up to 3+ participants into an Asterisk full-duplex ConfBridge.
   * **In-Call Real-Time Whisper Warning**: Asterisk `ChanSpy` / Originate injects an audible warning (*"⚠️ Warning: Potential Scam Detected"*) directly into the callee's earpiece without dropping the call.
   * **Call Screening `8000`**: Interactive IVR records caller's name, rings callee, and offers Accept (1), Decline (2), or Voicemail (3).
4. **Speech-to-Text & AI Verdict**: `NativeVoskService.java` transcribes voice audio in-JVM via Vosk JNI and sends the transcript to the AI Decider (`POST /api/v1/voice/filter`). Malicious calls trigger automated subscriber blacklisting and SIP `403 Forbidden`.

### B. SMS Interception & Cross-Generation Bridging
[![SMS Interception Flow](docs/sms_interception_flow.png)](docs/sms_interception_flow.svg)

1. **5G $\rightarrow$ 2G Flow**: 5G UE sends SIP `MESSAGE` to Kamailio $\rightarrow$ Kamailio inspects body and queries `telecom-api` $\rightarrow$ IP-SM-GW receives message, converts to SMPP `submit_sm` $\rightarrow$ OsmoSMSC delivers to 2G Mobile Station handset.
2. **2G $\rightarrow$ 5G Flow**: 2G MS sends SMS to OsmoSMSC $\rightarrow$ IP-SM-GW polls `smsc.db` $\rightarrow$ bridges message into SIP `MESSAGE` $\rightarrow$ Kamailio delivers to 5G recipient softphone.
3. **AI Smishing URL Sandbox**: SMS text containing shortened links (`bit.ly`, `tinyurl`) is analyzed for phishing heuristics before delivery.

---

## 3. Technology Stack

| Domain | Technology | Specification / Version |
| :--- | :--- | :--- |
| **Signaling Proxy** | Kamailio | v5.7 (SIP Proxy, Registrar, Jansson, USRLOC) |
| **Media Plane** | RTPEngine + Asterisk | RTPEngine NG (Relay) + Asterisk 20.6 (ConfBridge MCU, ChanSpy Whisper, IVR) |
| **Cellular SMS** | Osmocom Stack | `osmo-smsc` (SMPP 3.4) + `osmo-hlr` (GSUP) + `osmo-msc` |
| **SMS Bridge** | IP-SM-GW | TS 23.204 Python 3.11 Async Bridge (35 Unit Tests) |
| **5G SA Core** | Open5GS + UERANSIM | 10 3GPP Release 16 NFs + simulated gNodeB & 3 UEs (S-NSSAI Slicing) |
| **Policy Engine** | Spring Boot 3.4.3 | Java 21 LTS, Virtual Threads, RestClient, JdbcTemplate |
| **Speech-to-Text** | Vosk ASR JNI | In-JVM Native C library bindings (<2.0s latency, offline) |
| **Observability** | VictoriaMetrics + Grafana | VictoriaMetrics TSDB + `vmagent` Scraper + Grafana 11.6 Unified NOC |
| **Databases** | SQLite (WAL) + MongoDB | SQLite 3 (Kamailio, OCS, HLR) + MongoDB 6 (Open5GS UDR) |
| **Host Audio** | PipeWire / PulseAudio | Real-time full-duplex ALSA/Pulse hardware routing |

---

## 4. Operational & Demo Commands

```bash
# 1. Bring up Full 5-Repo Ecosystem (40+ Containers)
make all-up

# 2. Run Zero-Mock Real-World Hardware-In-The-Loop Smoke Test
make smoke-test

# 3. Launch Live Call Status & Host Microphone VU-Meter HUD
make monitor

# 4. Run 3-Way Conference Bridge Demo (Android + 2 Laptop UEs)
python3 scripts/testing/conference_3way_demo.py

# 5. Run In-Call Audio Whisper Warning Demo (ChanSpy)
python3 scripts/testing/whisper_warning_demo.py

# 6. Open Live Wireshark Packet Capture
make wireshark

# 7. Access Unified Grafana NOC Dashboard
http://localhost:3000   (or http://<HOST-IP>:3000)
```


# 2. Initialize SQLite databases (Kamailio, OCS, HLR)
make init-db

# 3. Launch the 37-container stack
make up

# 4. Seed MongoDB 5G subscribers and verify functional health
make seed-mongo && make bootstrap-check
```

---

## 5. Network Ports & Service Map

| Service | Container Name | Port / Binding | Protocol | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Spring Boot Gateway** | `mvno-api` | `8080` (host) | HTTP / REST | Interception policy, OCS balance, subscriber API |
| **Kamailio SIP Proxy** | `mvno-kamailio` | `5060` (host) | UDP / TCP | SIP signaling, digest challenge, USRLOC |
| **Asterisk Media Server** | `mvno-asterisk` | `5061` (internal) | UDP | ConfBridge 7XXX, Screening 8000, Voicemail 8XXX |
| **RTPEngine Media Relay** | `mvno-rtpengine` | `10000-20000` (host) | UDP | Bidirectional RTP audio stream relay |
| **OsmoSMSC (2G SMS)** | `mvno-osmosmsc` | `2775` (host) | TCP / SMPP | Cellular SMS store-and-forward (SMPP 3.4) |
| **IP-SM-GW Bridge** | `mvno-ip-sm-gw` | `5090` (SIP) + `2775` | UDP / SMPP | 2G SMSC $\leftrightarrow$ 5G SIP MESSAGE interworking |
| **VictoriaMetrics** | `mvno-victoriametrics`| `8428` (host) | HTTP | Carrier TSDB & PromQL query engine |
| **Grafana NOC** | `mvno-grafana` | `3000` (host) | HTTP | Real-time visual network operations dashboard |
| **Open5GS WebUI** | `mvno-open5gs-webui`| `9999` (host) | HTTP | 5G subscriber SIM & slice management UI |
| **AI Spam Classifier** | `ai-filter` | `8008` (host $\rightarrow$ 8000) | HTTP / REST | AI content classification decision engine |

---

## 6. Live Demonstration & Verification Cockpits

```
┌────────────────────────────────────────────────────────────────────────┐
│                        DEMONSTRATION INTERFACES                        │
├─────────────────────┬──────────────────────────┬───────────────────────┤
│ Interface           │ Command / URL            │ Key Capabilities      │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│ 🎮 Master Menu      │ bash scripts/demo/       │ Interactive run-card: │
│    (User Demo)      │   user_demo.sh           │ • Mic hardware probe  │
│                     │                          │ • SMS interworking    │
│                     │                          │ • Live voice calls    │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│ 🖥️ NOC Cockpit      │ bash scripts/noc.sh      │ 8-pane synchronized   │
│    (Terminal TUI)   │                          │ terminal grid showing │
│                     │                          │ SIP, RTP, SMS, Vosk   │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│ 📊 Grafana Web NOC  │ http://localhost:3000    │ Live visual graphs of │
│    (Browser GUI)    │                          │ calls, SMS, & blocks  │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│ 📱 Android Mobile   │ Linphone App on Phone    │ Physical handset for  │
│    (Handset GUI)    │ (192.168.100.93:5060)    │ calls, SMS, & Conf    │
└─────────────────────┴──────────────────────────┴───────────────────────┘
```

---

## 7. Documentation Directory Map

| Document | Purpose & Scope |
| :--- | :--- |
| [`ONBOARDING.md`](ONBOARDING.md) | Comprehensive team guide: setup, environment matrix, and make targets. |
| [`docs/LIVE_DEMO.md`](docs/LIVE_DEMO.md) | The authoritative live demo playbook (Sections S1–S16): voice, SMS, ConfBridge, and screening. |
| [`docs/TESTING_REFERENCE.md`](docs/TESTING_REFERENCE.md) | Multi-terminal testing reference: scripted variants of all test flows (Flows A–P). |
| [`docs/INTEGRATION_CONTRACT.md`](docs/INTEGRATION_CONTRACT.md) | Version 1.2 cross-organization API contracts, payload schemas, and SLAs. |
| [`docs/partner/`](docs/partner/) | Dedicated partner integration runbooks (`Filteration-System`, `sms-client`, `SipClient`). |
| [`docs/ARCHITECTURE_DECISIONS.md`](docs/ARCHITECTURE_DECISIONS.md) | Architecture Decision Records (ADR Decisions D1–D8). |
| [`docs/ISSUES.md`](docs/ISSUES.md) | Root cause analysis catalog covering **68 resolved engineering issues** (Frontier: Issue 8.68). |
| [`docs/device-registration-linphone-mizudroid.md`](docs/device-registration-linphone-mizudroid.md) | Android/iOS softphone onboarding guide (Linphone, MizuDroid, SIP credentials). |
| [`docs/deployment_guide.md`](docs/deployment_guide.md) | Production and containerized deployment runbook. |
| [`docs/GLOSSARY.md`](docs/GLOSSARY.md) | Single Source of Truth for telecom and project acronyms. |