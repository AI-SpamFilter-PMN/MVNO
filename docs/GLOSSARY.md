# 📖 Telecom & SRE Universal Acronym Glossary & Standards Dictionary

> **Authoritative reference for all abbreviations, acronyms, protocols, 3GPP standards, and IETF RFCs used across the MVNO Telecom Core, AI Spam Filter, and Observability Mesh.**

---

## 📑 Table of Contents

1. [3GPP & 5G Standalone (5GC / RAN)](#1-3gpp--5g-standalone-5gc--ran)
2. [SIP Signaling, IMS & Media Plane](#2-sip-signaling-ims--media-plane)
3. [Cybersecurity, Anti-Fraud & STIR/SHAKEN](#3-cybersecurity-anti-fraud--stirshaken)
4. [AI, DSP Speech Recognition & Acoustic Analysis](#4-ai-dsp-speech-recognition--acoustic-analysis)
5. [Telephony Business Logic, OCS, EIR & SMS](#5-telephony-business-logic-ocs-eir--sms)
6. [Site Reliability Engineering (SRE), Observability & Containers](#6-site-reliability-engineering-sre-observability--containers)

---

## 1. 3GPP & 5G Standalone (5GC / RAN)

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **3GPP** | 3rd Generation Partnership Project | Global Telecommunications Consortium | The standards body defining GSM (2G), UMTS (3G), LTE (4G), 5G NR, and 6G specifications. |
| **5GC** | 5G Core Network | 3GPP TS 23.501 / TS 23.502 | The Service-Based Architecture (SBA) core controlling 5G user registration, session management, and data forwarding. |
| **5G SA** | 5G Standalone | 3GPP Rel-15 / Rel-16 | Pure 5G deployment with 5G NR radio directly connected to a cloud-native 5G Core (no 4G LTE anchor required). |
| **AMF** | Access and Mobility Management Function | 3GPP TS 23.502 (Open5GS `amfd`) | Terminates NGAP (N2) signaling from gNodeB and NAS (N1) signaling from UEs; handles registration, authentication, and mobility. |
| **SMF** | Session Management Function | 3GPP TS 23.502 (Open5GS `smfd`) | Manages PDU session creation, IP address allocation, and controls UPF data plane paths over PFCP (N4). |
| **UPF** | User Plane Function | 3GPP TS 23.501 (Open5GS `upfd`) | High-performance packet processing engine routing decapsulated IP data between gNodeB GTP-U tunnels and external DN (`ogstun`). |
| **NRF** | Network Repository Function | 3GPP TS 29.510 (Open5GS `nrfd`) | Microservice discovery registry where all 5GC network functions register and discover available services. |
| **AUSF** | Authentication Server Function | 3GPP TS 33.501 (Open5GS `ausfd`) | Authenticates 5G subscriber identity using 5G-AKA and EAP-AKA' cryptographic algorithms. |
| **UDM** | Unified Data Management | 3GPP TS 29.503 (Open5GS `udmd`) | Manages subscriber profiles, encryption keys, and credentials (equivalent to 4G HSS / 2G HLR). |
| **UDR** | Unified Data Repository | 3GPP TS 29.504 (Open5GS `udrd`) | Database storage backend holding persistent subscriber credentials and policy data for UDM and PCF. |
| **PCF** | Policy Control Function | 3GPP TS 29.512 (Open5GS `pcfd`) | Enforces dynamic QoS policies, bandwidth rules, and charging parameters per network slice. |
| **NSSF** | Network Slice Selection Function | 3GPP TS 29.531 (Open5GS `nssfd`) | Selects appropriate network slice instances (S-NSSAI) based on subscriber subscription and requested service. |
| **gNB** | Next Generation NodeB | 3GPP TS 38.300 (UERANSIM `nr-gnb`) | 5G NR base station handling radio transmission and communicating with 5GC over N2 (NGAP) and N3 (GTP-U). |
| **UE** | User Equipment | 3GPP TS 23.501 (UERANSIM / Phone) | Mobile subscriber device (smartphone, modem, or simulated UE `nr-ue`) connecting over radio interface (Uu). |
| **PDU** | Protocol Data Unit | 3GPP TS 23.501 | Data packet transmitted across the network; a **PDU Session** is the end-to-end IP data tunnel connecting UE to DN. |
| **SST** | Slice/Service Type | 3GPP TS 23.501 (SST=1 for eMBB) | Standard slice category identifier (1: eMBB, 2: URLLC, 3: MIoT/mMTC, 4: V2X). |
| **SD** | Slice Differentiator | 3GPP TS 23.501 | Optional 24-bit hex identifier differentiating distinct slices sharing the same SST. |
| **eMBB** | Enhanced Mobile Broadband | 3GPP 5G Use Case | High-bandwidth 5G network slice designed for streaming, downloads, and web traffic. |
| **URLLC** | Ultra-Reliable Low-Latency Communication | 3GPP 5G Use Case | Sub-millisecond latency slice for mission-critical industrial, medical, and autonomous applications. |
| **mMTC** | Massive Machine-Type Communication | 3GPP 5G Use Case | Low-power, high-density IoT network slice for smart meters and sensors. |
| **GTP-U** | GPRS Tunneling Protocol User Plane | 3GPP TS 29.281 (UDP Port 2152) | Encapsulates subscriber IP traffic between gNodeB and UPF across the N3 interface. |
| **NGAP** | Next Generation Application Protocol | 3GPP TS 38.413 (SCTP Port 38412) | Control-plane signaling protocol connecting gNodeB to AMF across the N2 interface. |
| **PFCP** | Packet Forwarding Control Protocol | 3GPP TS 29.244 (UDP Port 8805) | Control protocol connecting SMF to UPF across the N4 interface to establish packet forwarding rules. |
| **NAS** | Non-Access Stratum | 3GPP TS 24.501 | Signaling messages exchanged directly between UE and 5G AMF without radio layer interpretation. |
| **ogstun** | Open5GS TUN Interface | Linux Kernel Virtual TUN (`10.45.0.1/16`) | Virtual network interface inside UPF container where decapsulated 5G PDU traffic enters the IP network. |
| **uesimtun0** | UERANSIM TUN Interface | Linux Virtual TUN (`10.45.0.5`) | Virtual network interface inside simulated 5G UE container bound to active 5G PDU session. |

---

## 2. SIP Signaling, IMS & Media Plane

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **SIP** | Session Initiation Protocol | IETF RFC 3261 (UDP/TCP Port 5060) | Application-layer signaling protocol used for creating, modifying, and terminating voice and multimedia sessions. |
| **SDP** | Session Description Protocol | IETF RFC 4566 | Text format embedded in SIP payloads describing streaming media parameters (IPs, UDP ports, audio codecs, clock rates). |
| **RTP** | Real-time Transport Protocol | IETF RFC 3550 (UDP Ports 10000–20000) | Transport protocol delivering audio/video media packets with timestamps and sequence numbers for jitter reconstruction. |
| **RTCP** | RTP Control Protocol | IETF RFC 3550 | Companion protocol to RTP delivering out-of-band telemetry on media packet loss, round-trip delay, and jitter. |
| **SRTP** | Secure Real-time Transport Protocol | IETF RFC 3711 | Encrypted profile of RTP providing media confidentiality, message authentication, and replay protection. |
| **IMS** | IP Multimedia Subsystem | 3GPP TS 23.228 | Architectural framework for delivering IP multimedia services (VoLTE, VoNR, Rich Communication Services). |
| **AoR** | Address of Record | IETF RFC 3261 (`sip:user@domain`) | Canonical public SIP address representing a subscriber identity in registrar databases (Kamailio `usrloc`). |
| **PJSIP** | PJSIP SIP/Media Stack | Open Source Telecom Library | C library powering Asterisk SIP channels and Baresip softphone endpoints. |
| **RTPEngine** | NGCP RTPEngine | Sipwise In-Kernel Media Proxy | High-throughput kernel-space RTP proxy anchoring and relaying media packets between NATed endpoints. |
| **ChanSpy** | Asterisk Channel Spy | Asterisk PBX Core Application | Audio monitoring engine allowing real-time call audio tapping and whisper mode voice injection (`whisper-audio`). |
| **ConfBridge** | Asterisk Conference Bridge | Asterisk PBX Application (RFC 4579) | Multi-party audio mixing engine supporting full-duplex conferencing, pinned users, and dynamic room creation. |
| **PSAP** | Public Safety Answering Point | NENA / 3GPP TS 23.167 (RFC 6881) | Emergency call dispatch center handling 911 / 112 calls; Kamailio bypasses auth and routes to Asterisk PSAP trunk. |
| **ESNet** | Emergency Services Network | RFC 6881 (`Resource-Priority: esnet.0`) | Dedicated priority header attached to SIP emergency calls guaranteeing priority resource preemption. |
| **DTMF** | Dual-Tone Multi-Frequency | IETF RFC 4733 / RFC 2833 | Touch-tone keypad signaling transmitted in-band or via RTP telephone-event packets for IVR menu navigation. |
| **IVR** | Interactive Voice Response | Telephony Subsystem | Automated voice menu system playing pre-recorded audio prompts and accepting DTMF / voice responses. |
| **MOS** | Mean Opinion Score | ITU-T P.800 (Scale: 1.0 – 5.0) | Standard empirical metric evaluating perceived voice quality and clarity across audio codecs. |

---

## 3. Cybersecurity, Anti-Fraud & STIR/SHAKEN

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **STIR** | Secure Telephony Identity Revisited | IETF RFC 8224 | Architecture defining cryptographic attestation tokens (PASSporT) embedded in SIP `Identity` headers. |
| **SHAKEN** | Signature-based Handling of Asserted information using toKENs | ATIS-1000074 / RFC 8588 | Operational framework defining carrier certificate governance and attestation levels (Full A, Partial B, Gateway C). |
| **PASSporT** | Personal Assertion Token | IETF RFC 8225 / RFC 8588 | Base64URL-encoded JWT token asserting caller ID authenticity, containing `orig`, `dest`, `iat`, and `origid` claims. |
| **JOSE** | Javascript Object Signing and Encryption | IETF RFC 7515 | Cryptographic JSON header format specifying signature algorithms (`alg: "ES256"`, `ppt: "shaken"`, `x5u`). |
| **ES256** | ECDSA using P-256 and SHA-256 | FIPS 186-4 / RFC 7518 | Mandatory cryptographic signature algorithm for STIR/SHAKEN PASSporT signing. |
| **ECDSA** | Elliptic Curve Digital Signature Algorithm | ANSI X9.62 | Asymmetric cryptography providing high-security digital signatures with compact 256-bit key sizes. |
| **x5u** | X.509 Certificate URL | IETF RFC 8224 | HTTPS URI in PASSporT header pointing to carrier's public X.509 certificate for signature verification. |
| **SSRF** | Server-Side Request Forgery | CWE-918 | Vulnerability where an attacker tricks a server into querying internal IPs; guarded in Smishing Sandbox. |
| **Smishing** | SMS Phishing | Cybersecurity Threat Vector | Malicious SMS messages containing deceptive text and weaponized URLs designed to harvest credentials. |
| **Robocall** | Automated Spammed Voice Call | Telecom Threat Vector | Bulk automated phone calls delivering fraudulent marketing or phishing voice recordings. |
| **Spoofing** | Caller ID Impersonation | Fraud Technique | Falsifying the SIP `From` header to disguise caller identity as a legitimate bank, government, or executive. |
| **DPI** | Deep Packet Inspection | Network Security | Inspecting packet payloads at Layer 7 (DNS, TLS SNI, HTTP) rather than just Layer 3/4 headers. |

---

## 4. AI, DSP Speech Recognition & Acoustic Analysis

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **ASR** | Automatic Speech Recognition | Speech Processing Subsystem | Converting spoken acoustic waveforms into structured textual phonemes and words. |
| **Vosk** | Vosk Offline Speech Recognition | Alpha Cephei Speech Engine | Lightweight, offline, sub-100ms latency ASR engine running in Java 21 via native JNI bindings. |
| **JNI** | Java Native Interface | Oracle Java Standard | C/C++ bridge allowing Java 21 to invoke native C compiled shared libraries (`libvosk.so`) in-process. |
| **DSP** | Digital Signal Processing | Audio Mathematics | Mathematical algorithms analyzing and transforming digital audio buffers in real-time. |
| **FFT** | Fast Fourier Transform | Cooley-Tukey Algorithm | Computes Discrete Fourier Transform, converting time-domain PCM audio into frequency-domain spectral bins. |
| **Spectral Centroid** | Audio Brightness Center-of-Mass | DSP Metric ($\text{Hz}$) | Center of mass of the frequency spectrum; synthetic TTS exhibits unnaturally static spectral centroids. |
| **ZCR** | Zero-Crossing Rate | DSP Audio Metric | Rate at which audio signal waveform crosses zero voltage; indicates voice roughness and unvoiced phonemes. |
| **Pitch Jitter** | Fundamental Frequency Cycle-to-Cycle Perturbation | Acoustic Biometric ($\%$) | Natural human vocal folds vibrate with $\approx 0.5\% - 2.5\%$ micro-timing variation; TTS engines produce $<0.15\%$ jitter. |
| **PCM** | Pulse-Code Modulation | ITU-T G.711 ($\text{16-bit linear}$) | Uncompressed digital representation of raw sampled analog audio signals. |

---

## 5. Telephony Business Logic, OCS, EIR & SMS

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **IMSI** | International Mobile Subscriber Identity | 3GPP TS 23.003 (15-digit code) | Unique hardware identity stored in SIM cards identifying subscriber country, network, and account (`MCC-MNC-MSIN`). |
| **IMEI** | International Mobile Equipment Identity | 3GPP TS 22.016 (15-digit code) | Unique hardware serial number identifying the physical smartphone handset. |
| **MSISDN** | Mobile Station International Subscriber Directory Number | ITU-T E.164 (`15553332211`) | The public telephone number dialed to reach a mobile subscriber. |
| **EIR** | Equipment Identity Register | 3GPP TS 22.011 / TS 23.018 | Database tracking valid, blocked (blacklisted), and stolen IMEIs; detects unauthorized SIM-swap attacks. |
| **OCS** | Online Charging System | 3GPP TS 32.296 | Real-time prepaid billing ledger authorizing subscriber balances before call or SMS delivery. |
| **OFCS** | Offline Charging System | 3GPP TS 32.295 | Postpaid CDR (Call Detail Record) processing engine for historical billing audits. |
| **SMSC** | Short Message Service Center | 3GPP TS 23.040 (Osmocom SMSC) | Network store-and-forward switch responsible for routing and delivering SMS messages. |
| **SMPP** | Short Message Peer-to-Peer | SMPP v3.4 (TCP Port 2775) | Standard telecommunications industry protocol for exchanging SMS messages between SMSCs and applications (ESME). |
| **IP-SM-GW** | IP Short Message Gateway | 3GPP TS 23.204 (MVNO Bridge) | Protocol converter bridging legacy 2G/3G SMPP SMS with 5G IMS SIP MESSAGE text messages. |
| **USSD** | Unstructured Supplementary Service Data | 3GPP TS 24.090 (`*100#`) | Real-time, session-oriented interactive GSM/5G text menu system for subscriber self-care and account balance. |
| **MAP** | Mobile Application Part | 3GPP TS 29.002 | SS7 signaling protocol used for roaming, SMS delivery, and subscriber location lookups. |
| **CAMEL** | Customised Applications for Mobile networks Enhanced Logic | 3GPP TS 23.078 | Standard allowing operator to provide intelligent prepaid routing across roaming networks. |

---

## 6. Site Reliability Engineering (SRE), Observability & Containers

| Acronym | Full Form | Standard / Reference | Definition & Role in MVNO |
| :--- | :--- | :--- | :--- |
| **NOC** | Network Operations Center | Carrier Operations | Centralized control room monitoring carrier signaling, media relay, availability, and network health. |
| **SOC** | Security Operations Center | Cyber Defense Operations | Centralized security team analyzing threat intelligence, smishing attacks, fraud robocalls, and DPI alerts. |
| **TSDB** | Time-Series Database | VictoriaMetrics (Port 8428) | Specialized database optimized for storing timestamped numeric metrics and high-cardinality telemetry. |
| **PromQL** | Prometheus Query Language | CNCF Observability Standard | Query language for computing mathematical aggregations, rates, and thresholds over time-series metrics. |
| **LogQL** | Log Query Language | VictoriaLogs (Port 9428) | High-speed structured log query language for searching carrier interception events and security logs. |
| **SLA** | Service Level Agreement | Carrier Contract Standard | Formal commitment between carrier and customer (e.g. Telecom Gateway 5.0s fail-open guarantee). |
| **SLO** | Service Level Objective | SRE Reliability Target | Internal reliability target measured over time (e.g. 99.99% successful SIP INVITE processing). |
| **SLI** | Service Level Indicator | Quantitative Metric | Real-time metric measuring performance against SLO (e.g. `sum(rate(mvno_call_blocked_total[5m]))`). |
| **MTTR** | Mean Time to Recovery | SRE Operational Metric | Average time required to diagnose, repair, and restore a failed telecom service. |
| **MTTD** | Mean Time to Detect | SRE Operational Metric | Average time between fault occurrence and NOC alert triggering. |
| **cgroup v2** | Control Groups Version 2 | Linux Kernel Subsystem | Unified Linux hierarchy managing container CPU, memory, I/O, and PID resource constraints. |
| **netns** | Network Namespace | Linux Kernel Isolation | Isolated network stack (interfaces, routing tables, sockets); UPF and 5G DPI share container netns. |
| **SELinux** | Security-Enhanced Linux | NSA / Red Hat Linux Security | Mandatory access control (MAC) security architecture; container volume mounts require `:z` labels. |
| **vmagent** | VictoriaMetrics Agent | Lightweight Scraper | Low-resource Prometheus target scraper collecting metrics from UPF, RTPEngine, and Telecom API. |
