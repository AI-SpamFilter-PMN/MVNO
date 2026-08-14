# 📱 MVNO 5G Standalone & Telecom Interception Core

> **Carrier-Grade 3GPP Rel-16 5G Standalone Core, Kamailio SIP Interception, In-Kernel RTPEngine Media Relay, AI Speech & Voice Clone DSP Analysis, STIR/SHAKEN Cryptographic Mesh, and Tier-1 Carrier NOC Observability.**

[![Orchestration](https://img.shields.io/badge/Orchestration-Podman--Compose_%7C_Docker-orange?style=for-the-badge&logo=podman)](docs/deployment_guide.md)
[![Database](https://img.shields.io/badge/Database-SQLite_WAL_%7C_MongoDB-green?style=for-the-badge&logo=sqlite)](docs/deployment_guide.md)
[![Observability](https://img.shields.io/badge/Observability-VictoriaMetrics_%7C_Grafana_NOC-purple?style=for-the-badge&logo=grafana)](docs/deployment_guide.md)
[![5G Core](https://img.shields.io/badge/5G_Core-Open5GS_SA_%7C_UERANSIM-blue?style=for-the-badge)](docs/implementation_guide.md)
[![AI Security](https://img.shields.io/badge/AI_Security-Smishing_Sandbox_%7C_DSP_Clone_Detector-red?style=for-the-badge)](docs/implementation_guide.md)
[![Glossary](https://img.shields.io/badge/Dictionary-100%2B_Telecom_Acronyms-teal?style=for-the-badge)](docs/GLOSSARY.md)

---

## 🏛️ 1. High-Level Architecture Topology

The MVNO core network operates as an unprivileged, rootless multi-service stack composed of **37+ orchestrated containers** spanning signaling, media, 5G packet core, AI intelligence, and telemetry:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   MVNO CORE ARCHITECTURE TOPOLOGY                                │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                  │
│  [Physical Phone / SIP UA] ──▶ Kamailio (Edge Proxy :5060) ──▶ RTPEngine (Kernel Media Relay)    │
│                                    │                                  │ (Audio Forking)          │
│                                    ├──▶ Asterisk 20.6 (:5061)        ▼                           │
│                                    │    (ConfBridge 7XXX, IVR 8000)  Spring Boot Gateway (:8080) │
│                                    │    (Emergency 911/112 PSAP)     (Native Vosk ASR JNI)       │
│                                    ▼                                 (AI Voice Clone DSP)        │
│  [5G SA Radio (UERANSIM)]  ──▶ Open5GS 5GC (10 NFs)                  (STIR/SHAKEN ES256)         │
│                                    │                                          │                  │
│                                    ├──▶ 5G L7 DPI Probe (:9094)               ▼                  │
│                                    │    (ogstun / GTP-U Sniffer)     AI Spam Filter (:8000)      │
│                                    ▼                                 (allow / block decision)    │
│  [2G GSM MS (OsmocomBB)]   ──▶ OsmoSMSC (:2775) ──▶ IP-SM-GW (:5090) ────────┘                  │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Core Architectural Layers:
1. **Signaling & Edge Proxy**: **Kamailio 5.7** handles SIP registrations (digest-challenged), policy routing, international MSISDN prefix normalization, SMS payload parsing, and Layer 0 Emergency priority preemption.
2. **Media Plane & Transcoding**: **RTPEngine NG** provides in-kernel userspace RTP media relaying and call recording forking. **Asterisk 20.6** acts as an MCU sidecar providing audio mixing for **ConfBridge `7001` / RFC 4579 `conf-factory`**, **In-Call Audio Whisper Warnings**, **Interactive Call Screening `8000`**, and **Emergency 911 PSAP Trunk**.
3. **Hardware Audio Integration**: Host-native **PipeWire / PulseAudio** integration provides real-time, full-duplex hardware microphone capture and speaker output across endpoints without file-based intermediary buffering.
4. **SMS Interworking & Control**: Osmocom (`OsmoSMSC` + `OsmoHLR`) provides GSM 03.40 store-and-forward SMSC capabilities. A **TS 23.204 IP-SM-GW bridge** (`mvno-ip-sm-gw`) bi-directionally bridges 2G SMPP messages with 5G/IMS SIP `MESSAGE` transactions.
5. **AI Interception & Policy Core**: **Spring Boot 3.4.3** (Java 21 LTS, Virtual Threads, SQLite WAL OCS balance check, EIR SIM-swap fraud protection, and in-JVM native **Vosk ASR JNI** for sub-100ms real-time speech-to-text).
6. **5G Standalone (SA) Core & L7 DPI**: **Open5GS** (10 NFs: NRF, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) + **UERANSIM** (gNB + 3 UEs) with S-NSSAI Network Slicing (`SST=1` eMBB vs `SST=2` URLLC) and an **in-netns L7 Deep Packet Inspection (DPI) Probe** capturing decapsulated GTP-U traffic directly off `ogstun`.
7. **Tier-1 Carrier Observability**: **VictoriaMetrics TSDB** + **VictoriaLogs** + **Grafana 11.6** with 5 specialized operational dashboards and a real-time **Live Operator Supervisor Cockpit** (`:8085`).

---

## 🌟 2. SOTA Telecom & Anti-Fraud Innovations

```
┌────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────┐
│ SOTA Innovation Subsystem                              │ Standards Compliance & Engineering Implementation                      │
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **1. Deep Smishing URL Redirect Sandbox & SSRF Guard** │ • Unravels URL shorteners (bit.ly, tinyurl) via HTTP HEAD/GET chains.  │
│                                                        │ • Guarded against SSRF, private CIDRs (127.0.0.0/8, 10.0.0.0/8), loops.│
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **2. AI Voice Clone & Synthetic Audio DSP Detector**   │ • In-JVM mathematical DSP audio variance analysis in Java 21.          │
│                                                        │ • Computes Spectral Centroid (Hz) & Pitch Micro-Jitter (0.5%-2.5%).    │
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **3. STIR/SHAKEN Cryptographic Attestation (ES256)**   │ • RFC 8224 / RFC 8588 PASSporT tokens signed with ECDSA P-256 (ES256). │
│                                                        │ • Embeds canonical claims: orig, dest, iat, origid, x5u, and attest A. │
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **4. Stateful Interactive USSD Gateway (*100#)**       │ • 3GPP TS 24.090 interactive session menus delivered over SIP MESSAGE. │
│                                                        │ • Multi-step stateful navigation: Balance (1), Voucher (2), Slices (3).│
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **5. Emergency 911 / 112 Layer 0 Priority Preemption** │ • RFC 6881 / 3GPP TS 23.167 zero-delay emergency interception.         │
│                                                        │ • Kamailio bypasses auth, attaches Resource-Priority: esnet.0 headers. │
├────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
│ **6. 5G Core GTP-U / ogstun L7 DPI Packet Engine**     │ • Sits directly inside UPF container network namespace (network_mode). │
│                                                        │ • Intercepts decapsulated DNS (5353), TLS SNI (443), and HTTP on ogstun│
└────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────┘
```

---

## 🌐 3. Active Network Ports & Service Endpoints

| Port / Protocol | Container / Service | Purpose / Description | Interface / Binding |
| :--- | :--- | :--- | :--- |
| **`5060/udp`** | `mvno-kamailio` | Kamailio Edge SIP Proxy & Registrar (RFC 3261) | `0.0.0.0:5060` |
| **`5061/udp`** | `mvno-asterisk` | Asterisk Media MCU (ConfBridge, ChanSpy, Emergency PSAP) | `0.0.0.0:5061` |
| **`8080/tcp`** | `telecom-api` | Spring Boot 3.4.3 Carrier Gateway REST API | `0.0.0.0:8080` |
| **`8085/tcp`** | `cockpit-server` | Live Operator Supervisor Cockpit (WebRTC / SSE Telephony HUD) | `0.0.0.0:8085` |
| **`3000/tcp`** | `mvno-grafana` | Grafana Tier-1 Carrier NOC Suite (5 Dashboards) | `0.0.0.0:3000` |
| **`8428/tcp`** | `mvno-victoriametrics` | VictoriaMetrics TSDB & VMUI Metric Explorer | `0.0.0.0:8428` |
| **`9094/tcp`** | `mvno-5g-dpi` | 5G L7 DPI Prometheus Metrics Exporter (UPF Netns) | `10.89.0.14:9094` |
| **`9428/tcp`** | `mvno-victorialogs` | VictoriaLogs Structured Interception Log Search | `0.0.0.0:9428` |
| **`2775/tcp`** | `mvno-osmo-smsc` | Osmocom GSM SMSC (SMPP v3.4 Protocol) | `0.0.0.0:2775` |
| **`5090/udp`** | `mvno-ip-sm-gw` | 3GPP TS 23.204 IP Short Message Gateway Bridge | `0.0.0.0:5090` |
| **`10000–20000`**| `mvno-rtpengine` | In-Kernel UDP Real-Time Transport Protocol (RTP) Relay | `0.0.0.0:10000-20000` |
| **`38412/sctp`**| `mvno-amf` | 5G NGAP Control Plane Interface (N2 to gNodeB) | `10.89.0.11:38412` |
| **`2152/udp`** | `mvno-upf` | 5G GTP-U Data Plane Tunnel Interface (N3 to gNodeB) | `10.89.0.14:2152` |

---

## 🚀 4. Quickstart & Verification Commands

```bash
# 1. Start the entire containerized MVNO stack
podman compose up -d

# 2. Execute Master Hardware-in-the-Loop Smoke Test (7 Stages)
make smoke-test

# 3. Execute Advanced Carrier Innovations & Anti-Fraud Suite (6/6 PASS)
python3 scripts/testing/test_all_advanced_features.py

# 4. Strict SRE TSDB Prometheus Metrics Validation (43/43 Queries PASS)
python3 scripts/testing/verify_grafana_live_metrics.py

# 5. Launch Live Operator Supervisor Cockpit
python3 scripts/demo/cockpit_server.py
```

---

## 📊 5. Carrier NOC Operational Dashboards

Open Grafana at **[`http://localhost:3000`](http://localhost:3000)** *(Credentials: `admin` / `admin`)* $\rightarrow$ Folder **`MVNO NOC`**:

1. 🎛️ **[MVNO NOC — Unified](http://localhost:3000/d/mvno-unified-noc)**: Master Single-Pane Carrier Cockpit with high-density KPIs, interactive HTML topology canvas, cross-plane traffic velocity, and live audit logs.
2. 🛡️ **[MVNO SOC — AI Anti-Fraud & Cyber Security](http://localhost:3000/d/mvno-soc-antifraud)**: Threat intelligence summary, smishing URL redirect sandbox detections, STIR/SHAKEN attestation, and 5G DPI threats.
3. 📡 **[MVNO 5G SA — Core Network & Slicing](http://localhost:3000/d/mvno-5g-core-dpi)**: Open5GS AMF/SMF/UPF status, UERANSIM gNodeB/UEs, GTP-U N3 throughput, and L7 protocol breakdown.
4. 🎙️ **[MVNO IMS — Voice Signaling & RTP Media](http://localhost:3000/d/mvno-ims-voice-media)**: SIP INVITE latency, RTPEngine kernel-space media bandwidth, stuck stream detection, and packet errors.
5. ⚡ **[MVNO VictoriaMetrics System NOC](http://localhost:3000/d/mvno-victoriametrics-noc)**: TSDB storage, memory cache, scraper liveness, and retention.

---

## 📚 6. Documentation Directory

* 📖 **[Universal Telecom & SRE Acronym Glossary](docs/GLOSSARY.md)** (100+ defined abbreviations)
* 🚀 **[New Engineer Onboarding Runbook](ONBOARDING.md)**
* 🛠️ **[Subsystem Implementation Guide](docs/implementation_guide.md)**
* 🚢 **[Deployment & Rootless Container Guide](docs/deployment_guide.md)**
* 📋 **[Environment & Port Allocation Matrix](docs/ENVIRONMENT_MATRIX.md)**
* 🏛️ **[Architectural Decision Records (ADRs)](docs/ARCHITECTURE_DECISIONS.md)**
* 🎙️ **[Real-Time Audio Pipeline & Mixing Guide](docs/REALTIME_AUDIO.md)**
* 📞 **[Multi-Party 3-Way Conferencing Guide](docs/CONFERENCE_CALL_GUIDE.md)**
* 🎬 **[Audience & Evaluator Live Demo Script](docs/LIVE_DEMO.md)**