# MVNO Core — Abbreviation Glossary

Single source of truth for every domain abbreviation used across the repo's
documentation. Entries marked **[C]** are carried verbatim from the former
`implementation_guide.md` Appendix C. Universal terms (TCP, UDP, HTTP, JSON,
SQL, API, URL, AI, OS, CPU, GPU, RAM, ID, KB, DB, OK…) are intentionally NOT
listed — see the pinned ALLOWLIST in `scripts/check-glossary.sh`.

| Abbreviation | Full Form | Context |
|-------------|-----------|---------|
| **ALSA** | Advanced Linux Sound Architecture | Host sound backend — baresip pulse path (mic/playback) |
| **AMF** | Access and Mobility Management Function | 5GC — UE registration, mobility, connection management [C] |
| **AoR** | Address-of-Record | Public SIP identity a UA registers (`sip:user@host`) |
| **ASGI** | Asynchronous Server Gateway Interface | Python async web bridge (FastAPI comparisons) |
| **ASR** | Automatic Speech Recognition | Vosk-based transcription of recorded call legs |
| **AUSF** | Authentication Server Function | 5GC — subscriber authentication [C] |
| **BSC** | Base Station Controller | 2G RAN controller (OsmoBSC) |
| **BSF** | Binding Support Function | 5GC — PCF discovery [C] |
| **BSS** | Base Station Subsystem | 2G radio network (BTS + BSC) |
| **BTS** | Base Transceiver Station | 2G radio base station (OsmoBTS) |
| **CLI** | Command-Line Interface | Tool usage from a terminal |
| **CSCF** | Call Session Control Function | IMS control layer (SIP routing) |
| **DKMS** | Dynamic Kernel Module Support | Out-of-tree kernel module builds |
| **DL** | Downlink | RAN direction gNB → UE (see also UL) |
| **DRB** | Data Radio Bearer | 5G NR user-plane bearer between gNB and UE |
| **DTLS** | Datagram TLS | Secures RTP (WebRTC/ICE media paths) |
| **DTMF** | Dual-Tone Multi-Frequency | Touch-tone keypad signals during calls [C] |
| **DTO** | Data Transfer Object | API payload carrier (Java records) |
| **E2E** | End-to-End | Full-path tests/demo cells (sms_matrix) |
| **E2E-BLOCK** | Deterministic AI-block SMS marker | Body text that forces `allow=false` → 403, no delivery |
| **EEA** | EPS Encryption Algorithm | 4G ciphering — EEA0 = null cipher (no confidentiality) |
| **EIR** | Equipment Identity Register | Device IMEI tracking and SIM swap detection [C] |
| **ESME** | External Short Message Entity | SMS client that connects to an SMSC via SMPP [C] |
| **ESM** | ECMAScript Modules | Next.js module system (WebUI build) |
| **F-TEID** | Fully allocated Tunnel Endpoint Identifier | GTP-U gNB/SMF tunnel mapping (ISSUES root-cause analysis) |
| **FQDN** | Fully Qualified Domain Name | `host.domain` addressing |
| **GC** | Garbage Collection | JVM/Vector runtime memory management |
| **GERAN** | GSM EDGE Radio Access Network | 2G RAN (Osmocom stack) |
| **GIL** | Global Interpreter Lock | CPython threading constraint |
| **GLIBC** | GNU C Library | Host libc (baresip rig mounts) |
| **MM** | Mobility Management | 2G layer — `mobile -c /etc/osmocom/mobile.cfg` auto-attach (S2) |
| **NEA** | NR Encryption Algorithm | 5G ciphering — NEA1/2 (128-NEA1/NEA2) |
| **NIA** | NR Integrity Algorithm | 5G integrity — NIA0/1/2 (NIA0 = off) |
| **SMS** | Short Message Service | SMS paths (2G/IMS), SMSC store-and-forward |
| **SS7** | Signaling System No. 7 | PSTN/2G signaling — SIGTRAN/M3UA in this stack |
| **VT** | Virtual Threads | Java 21 LTS concurrency (JEP 444) — telecom-api |
| **gNB** | Next Generation NodeB | 5G NR base station (UERANSIM gnb) |
| **GPRS** | General Packet Radio Service | 2.5G packet data |
| **GSUP** | Generic Subscriber Update Protocol | OsmoHLR subscriber signaling toward MSC/SMSC |
| **GTP-U** | GPRS Tunneling Protocol — User Plane | 5GC — tunnel carrying user data between UPF and gNB [C] |
| **h2c** | HTTP/2 cleartext | SBI transport between Open5GS NFs (`no_tls: true`) |
| **HLR** | Home Location Register | Subscriber database (IMSI, MSISDN, services) [C] |
| **ICE** | Interactive Connectivity Establishment | WebRTC NAT traversal (best-practices review) |
| **IMEI** | International Mobile Equipment Identity | Unique hardware identifier for mobile devices [C] |
| **IMS** | IP Multimedia Subsystem | SIP-based control layer — IMS SMS-over-IP (S6d) |
| **IMSI** | International Mobile Subscriber Identity | Unique SIM card identifier [C] |
| **IP-SM-GW** | IP Short Message Gateway | TS 23.204 2G↔5G SMS bridge (`mvno-ip-sm-gw`) — TESTING_REFERENCE Flows B–C |
| **IVR** | Interactive Voice Response | Automated phone menus |
| **JDBC** | Java Database Connectivity | Spring Data access (Xerial SQLite JDBC) |
| **JDK** | Java Development Kit | Build/runtime — JDK 21 LTS |
| **JEP** | JDK Enhancement Proposal | e.g. JEP 444 (virtual threads) |
| **JNI** | Java Native Interface | JVM↔native bridge (Vosk bindings) |
| **JSX** | JavaScript XML | Next.js/React UI syntax (WebUI) |
| **JVM** | Java Virtual Machine | `mvno-telecom-api` runtime |
| **LAC** | Location Area Code | Cell tower grouping for geofencing [C] |
| **LTS** | Long-Term Support | JDK 21 LTS baseline |
| **M3UA** | MTP3 User Adaptation | SIGTRAN — SS7 over IP |
| **MCC** | Mobile Country Code | SIM/PLMN identity (with MNC) |
| **MESSAGE** | SIP method for instant messages | IMS SMS-over-IP (LIVE_DEMO S6c/S6d) |
| **MNC** | Mobile Network Code | SIM/PLMN identity (with MCC) |
| **MO** | Mobile Originated | SMS direction: from handset |
| **MS** | Mobile Station | 2G handset (`mvno-2g-ms` = MS1, MS2) |
| **MSC** | Mobile Switching Center | 2G voice/SMS switching (OsmoMSC) |
| **MSISDN** | Mobile Subscriber ISDN Number | The phone number (what you dial) [C] |
| **MT** | Mobile Terminated | SMS direction: to handset |
| **MVC** | Model-View-Controller | Spring Web MVC (`mvno-telecom-api`) |
| **MVNO** | Mobile Virtual Network Operator | This repo's core-network role |
| **NAS** | Non-Access Stratum | Signaling between UE and AMF |
| **NF** | Network Function | A 5GC logical component (AMF, SMF, UPF, etc.) [C] |
| **NG** | Next Generation | 5G-adjacent (NG-RAN, N26 interface) |
| **NGAP** | Next Generation Application Protocol | 5GC — signaling between gNB and AMF (N2 interface) [C] |
| **NOC** | Network Operations Center | Grafana command center (`noc_victoriametrics.json`) |
| **NRF** | Network Repository Function | 5GC — service registry for all NFs [C] |
| **NSSF** | Network Slice Selection Function | 5GC — selects network slice for UE [C] |
| **OBS** | Open Build Service | Osmocom package repositories |
| **OCS** | Online Charging System | Real-time prepaid balance management [C] |
| **OSI** | Open Systems Interconnection | Layered model (SIGTRAN/SS7 stacks) |
| **PCF** | Policy Control Function | 5GC — QoS and charging policies [C] |
| **PCMU** | G.711 μ-law PCM | RTP voice codec (S3 call media) |
| **PDU** | Protocol Data Unit | SMS PDU (SMPP) / 5GC PDU session |
| **PFCP** | Packet Forwarding Control Protocol | 5GC — control channel between SMF and UPF [C] |
| **PLMN** | Public Land Mobile Network | Mobile network identity (MCC + MNC) |
| **PMN** | Upstream platform repo alias | AI-SpamFilter-PMN (MVNO ↔ AI filter contract) |
| **PromQL** | Prometheus Query Language | VictoriaMetrics queries (LIVE_DEMO S9) |
| **PulseAudio** | Host sound server | baresip live-mic path (pulse module) |
| **R2DBC** | Reactive Relational Database Connectivity | Evaluated; no SQLite driver — WebFlux excluded |
| **RAN** | Radio Access Network | 2G/5G radio domain |
| **REST** | Representational State Transfer | Interception API (`mvno-api`, port 8080) |
| **RRC** | Radio Resource Control | Signaling between gNB and UE |
| **RTCP** | RTP Control Protocol | Media statistics alongside RTP |
| **RTP** | Real-time Transport Protocol | Voice media (S3 call) |
| **RTPEngine** | rtpengine media proxy | RTP anchor + pcap recording + DTMF logs |
| **SA** | Standalone | 5G SA core (no 4G anchor) |
| **SBI** | Service-Based Interface | 5GC — HTTP/2 communication between NFs [C] |
| **SCTP** | Stream Control Transmission Protocol | Transport for NGAP between gNB and AMF [C] |
| **SDP** | Session Description Protocol | SIP body describing media codecs, ports [C] |
| **SIGTRAN** | SS7-over-IP signaling transport | M3UA/SCTP family |
| **SIM** | Subscriber Identity Module | Card holding IMSI/keys |
| **SIP** | Session Initiation Protocol | Signaling protocol for voice/video calls [C] |
| **SIPREC** | SIP Recording | Recording metadata protocol |
| **SLA** | Service Level Agreement | Fallback whitelist when AI filter is unreachable [C] |
| **SMF** | Session Management Function | 5GC — PDU session establishment, IP allocation [C] |
| **SMPP** | Short Message Peer-to-Peer | Protocol for SMS exchange between ESME and SMSC [C] |
| **SMSC** | Short Message Service Center | Store-and-forward for SMS messages [C] |
| **SNAT** | Source NAT | Host MASQUERADE egress |
| **SRTP** | Secure RTP | Encrypted media (WebRTC path) |
| **STIR/SHAKEN** | Secure Telephony Identity Revisited / Signature-based Handling of Asserted information using toKENs | Anti-spoofing framework for SIP caller ID [C] |
| **STT** | Speech-to-Text | ASR synonym (Vosk) |
| **TEID** | Tunnel Endpoint Identifier | GTP-U tunnel identifier between UPF and gNB [C] |
| **Tier-1/2/3** | ASR fallback tiers | Live mic → spool file → seeded fixtures |
| **TLS** | Transport Layer Security | Encrypted transport (HTTPS, SRTP keying) |
| **TON** | Type of Number | SMPP addressing field (TON/NPI pair; NPI absent in this repo) |
| **TS** | Technical Specification | 3GPP specs (e.g. TS 23.204 IP-SM-GW) |
| **TSDB** | Time-Series Database | VictoriaMetrics |
| **TTS** | Text-to-Speech | espeak-ng canned phrases |
| **UA** | User Agent | baresip endpoints (rx/tx) |
| **UAS** | User Agent Server | SIP UA acting as server (demo rig) |
| **UDM** | Unified Data Management | 5GC — subscriber data store [C] |
| **UDR** | Unified Data Repository | 5GC — backend storage for UDM and PCF [C] |
| **UE** | User Equipment | 5G handset (`mvno-ueransim-ue-1/2`) |
| **UERANSIM** | UERANSIM | Open-source 5G UE + gNB simulator |
| **UL** | Uplink | RAN direction UE → gNB (see also DL) |
| **UPF** | User Plane Function | 5GC — packet forwarding, QoE enforcement [C] |
| **URI** | Uniform Resource Identifier | SIP/API addressing |
| **USSD** | Unstructured Supplementary Service Data | GSM service dialing (`*#` codes) |
| **VLR** | Visitor Location Register | 2G MSC location cache |
| **VM** | Virtual Machine | Host/guest virtualization |
| **vmagent** | VictoriaMetrics agent | Lightweight scrape + remote-write agent |
| **VictoriaMetrics** | VictoriaMetrics | PromQL-compatible time-series DB (`vm_*` metrics) |
| **Vosk** | Vosk | Offline ASR engine — 40 MB model, in-JVM (`NativeVoskService`) |
| **VRL** | Vector Remap Language | Vector transform language |
| **VTY** | Virtual terminal | Osmocom control interface (osmo-*) |
| **WAL** | Write-Ahead Log | SQLite durability mode (smsc.db, kamailio.db) |
| **WAV** | Waveform Audio | 16 kHz PCM recording files (spool, fixtures) |
| **X-API-Key** | API key header | Interception gateway auth (`mvno-demo-key-2026`) |
