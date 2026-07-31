# MVNO Core — Team Onboarding Guide

## 1. Project Identity

This repository contains a **complete MVNO 5G SA Core with real-time interception gateway**. It combines a standards-compliant 5G Standalone core (Open5GS + UERANSIM), an Osmocom-based cellular stack (HLR/MSC/SMSC), a Spring Boot interception gateway with native Vosk ASR, and an AI spam filter integration point — all orchestrated via rootless Podman/Docker Compose. It is **not** a production billing platform, a full IMS core, or a managed SaaS — it's a developer-grade stack for building and testing spam/voice interception logic.

## 2. Architecture Overview

```
┌─────────────┐    ┌─────────────┐    ┌──────────────────┐    ┌─────────────┐
│  5G SA Core │───▶│   Osmocom   │───▶│  Interception    │───▶│  AI Spam    │
│ (Open5GS +  │    │  (HLR/MSC/  │    │  Gateway         │    │  Filter     │
│  UERANSIM)  │    │   SMSC)     │    │ (Kamailio +      │    │  (External) │
│             │    │  SMPP/GSUP) │    │  rtpengine +     │    │             │
└─────────────┘    └─────────────┘    │  Vosk ASR +      │    └─────────────┘
       │                │             │  Spring Boot)    │           │
       ▼                ▼             └────────┬─────────┘           ▼
┌─────────────┐    ┌─────────────┐             │             ┌─────────────┐
│  Observability      │◀───────────────────┘    AI Spam Filter
│ (Vector → stdout / VM → Grafana)               (External Repo)
```

**Components:**
- **5G SA Core**: Open5GS 10 NFs (NRF, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) + UERANSIM gNB + 3 UEs
- **Osmocom Stack**: HLR (GSUP) + MSC/SMSC (SMPP 3.4) via `osmo-hlr` / `osmo-msc` / `osmo-smsc`
- **Interception Gateway**: Kamailio SIP registrar/proxy → `rtpengine` media fork → Vosk ASR (native JNI) → Spring Boot gateway (Java 21, virtual threads)
- **AI Spam Filter**: External REST service at `http://ai-filter:8000/api/v1/classify`
- **Observability**: Vector (stdout log driver) → VictoriaMetrics (metrics TSDB) → Grafana (4 pre-built dashboards)

**Diagrams:** `docs/architecture_flow.svg`, `docs/ims_voice_call_flow.svg`, `docs/sms_interception_flow.svg`

---

## 3. Prerequisites (Per OS)

| Distro | Command |
|--------|---------|
| Ubuntu/Debian | `apt install podman docker-compose-v2 sqlite3 lksctp-tools` |
| Fedora/RHEL | `dnf install podman podman-compose sqlite3 lksctp-tools` |
| Arch/CachyOS | `pacman -S podman docker-compose sqlite3 lksctp-tools` |
| **All** | `sudo modprobe sctp` (verify: `lsmod \| grep sctp`) |

> **Note**: SCTP kernel module is mandatory for 5G NGAP (gNB ↔ AMF). Without it, gNB never connects.
> **Air-Gapped / Offline Setup**: Run `./scripts/bootstrap.sh` once with internet access to vendor all container images, Vosk speech models, and pip wheels into `vendor/`. Run `./scripts/load-offline.sh` to load offline image tarballs into Podman.

---

## 4. Quickstart (Copy-Paste Ready)

```bash
git clone https://github.com/AI-SpamFilter-PMN/MVNO.git
cd MVNO
make init-db   # creates SQLite WAL DBs + seeds test subscribers
make up        # offline-first launch (27 containers)
make test      # runs test-vty + test-api + test-sms + test-call
```

---

## 5. Key Make Targets

| Target | Purpose |
|--------|---------|
| `make up` | Start container stack (offline-first, uses pre-loaded images) |
| `make down` | Stop container stack |
| `make ps` | List active container services |
| `make logs` | Stream live container logs across microservices |
| `make init-db` | Recreate SQLite WAL DBs + seed subscriber test records |
| `make seed-mongo` | Upsert 3 5G SA UERANSIM subscriber records into Open5GS MongoDB |
| `make clean` | `down -v` + wipe runtime state directories |
| `make rebuild` | `clean` → `init-db` → `up --build` |
| `make test-api` | Health check + subscriber endpoint verification |
| `make test-vty` | OsmoHLR/SMSC VTY socket verification |
| `make test-sms` | SMS simulation (SMPP → gateway → AI filter) |
| `make test-call` | Voice call simulation (SIP → gateway → AI filter) |
| `make test` | Runs all 4 test suites sequentially |
| `make up-native` | Starts native systemd services (`kamailio`, `ngcp-rtpengine`, `osmo-msc`, `osmo-hlr`) — requires `sudo`, systemd, and OS packages |
| `make init-native-db` | Alias for `init-db` for native systemd deployments |

---

## 6. AI Filter Integration (The Contract)

**Internal DNS:** `http://ai-filter:8000/api/v1/classify` (host port 8008)

**SMS Input:**
```json
{
  "event_type": "SMS",
  "sender_msisdn": "15551234567",
  "recipient_msisdn": "15557654321",
  "content_text": "Hello world",
  "timestamp_epoch_ms": 1699999999999
}
```

**Voice Input:**
```json
{
  "event_type": "VOICE_CALL",
  "caller_msisdn": "15551234567",
  "callee_msisdn": "15557654321",
  "call_id": "call-123",
  "timestamp_epoch_ms": 1699999999999
}
```

**Output:**
```json
{ "allow": true, "reason": "Clean content" }
```

**SLA:** 5s read timeout → fail-open (`allow: true`). Circuit breaker: 3 consecutive failures → 30s fast fail-open (~0.1ms).

**Current mock:** `ai-filter` container returns `allow: true` always. Replace with your model.

**Full schema:** `docs/API_CONTRACT.md`

---

### 6a. Layered Interception Pipeline

| Layer | Check | Block Condition |
|-------|-------|-----------------|
| 1. Prepaid OCS | SQLite balance ≤ 0 | `allow: false, "Prepaid balance exhausted"` |
| 2. EIR | IMEI→MSISDN binding >3 swaps/10min | `allow: false, "EIR: SIM swap detected"` |
| 3. AI Filter | External model classification | `allow: false, "AI: spam detected"` |

---

## 7. Configuration — Key File Reference

| File | Why |
|------|-----|
| `configs/osmocom/osmo-smsc.cfg` | `remote-ip 10.89.0.45` — static IP guaranteed by compose |
| `state/kamailio/kamailio.db` | Auto-generated by `make init-db` (WAL mode) |
| `configs/kamailio/kamailio.cfg` | Core SIP Routing & Security Logic — edit with care |
| `docker-compose.yml` service IPs | Static assignments for deterministic networking |

---

## 8. Testing & Verification

| Command | Expected |
|---------|----------|
| `make test-api` | `{"status":"UP"}` + subscriber JSON |
| `make test-vty` | `✓ HLR subscriber found` + `✓ Primary SMPP ESME configured` + `✓ Secondary client SMPP ESME configured` |
| `make test-sms` | `allow: true, "Clean content"` |
| `make test-call` | `allow: false, "EIR: SIM swap detected"` (test IMEI) |
| `make test` | All 4 pass |
| `cd telecom-api && ./mvnw test` | 22/22 pass (includes SLA + circuit breaker + distinct EIR + GET intercept + API-key interceptor tests) |

---

## 9. Observability

| Tool | URL | Purpose |
|------|-----|---------|
| Grafana | `http://localhost:3000` (admin/admin) | Dashboards: NOC, Telecom-API, Rtpengine, Overview |
| VictoriaMetrics | `http://localhost:8428` | Raw PromQL queries |
| vmagent | `http://localhost:8429` | Scrape config |
| Vector | Internal | Log pipeline (console stdout driver; VictoriaLogs on Roadmap) |

**Key metrics:** `mvno_sms_requests_total`, `mvno_sms_blocked_total`, `mvno_call_requests_total`, `mvno_call_blocked_total`, `mvno_call_blocked_eir_total`.

---

## 10. Known Limitations (Demo Day Risks)

| Area | Limitation |
|------|------------|
| **Vosk ASR** | English-only small model (50MB). Post-call only. ~10-15% WER. No Arabic. |
| **AI Filter Mock** | Returns `allow: true` always. Replace `ai-filter` container with your model. |
| **SIP Testing** | `make test-call` uses HTTP POST, not real SIP INVITE. No SIPp scenario included. |
| **SCTP Kernel** | `modprobe sctp` required on host. Fails silently if missing (gNB↔AMF never connects). |
| **RTPEngine Kernel** | Runs in userspace mode (kernel module not required). |
| **First-call ASR Cold Start** | Vosk model loads lazily on first transcription (~2-5s delay). |

---

## 11. Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| gNB never connects to AMF | SCTP module not loaded | `sudo modprobe sctp` (verify: `lsmod \| grep sctp`) |
| `make up` hangs on gNB | Image not built / missing | `make rebuild` or `./scripts/bootstrap.sh` |
| `test-vty` fails | Containers not ready | Wait 60s after `make up`; check `make ps` / `podman compose ps` |
| `mvno-vector` crashes | Podman socket path wrong | `export PODMAN_USER_UID=$(id -u)` before `make up` |
| No transcription in logs | Model not mounted | Run `./scripts/bootstrap.sh` to vendor model |
| `make init-db` fails | `sqlite3` not installed | Install `sqlite3` package |

---

## 12. Key Files to Read Next

| File | Why |
|------|-----|
| `docs/deployment_guide.md` | Full ops runbook, configs, Issue 8.x log |
| `docs/API_CONTRACT.md` | Formal JSON schema for AI filter |
| `docs/ISSUES.md` | 8.x issue log with root causes/fixes |
| `docs/architecture_flow.svg` | System diagram |
| `docs/implementation_guide.md` | Deep dive architecture and configuration guide |
| `telecom-api/src/main/java/com/mvno/intercept/filter/AiFilterService.java` | Fail-open + circuit breaker logic |

---

## 13. Key Repos / Upstream Projects

| Component | Upstream Repo |
|-----------|---------------|
| 5G Core | `open5gs/open5gs` (v2.8.0) |
| RAN Simulator | `aligungr/UERANSIM` (v3.2.6) |
| SIP Proxy | `mvno-kamailio` (5.7.2, Alpine 3.19 build) |
| Media Proxy | `drachtio/rtpengine` (mr9.4.0.0) |
| HLR/MSC/SMSC | `osmocom/osmocom` (osmo-msc, osmo-hlr, osmo-smsc) |
| ASR | `alphacep/vosk-api` (v0.3.45) + `vosk-model-small-en-us-0.15` |
| Metrics TSDB | `victoriametrics/victoria-metrics` (v1.101.0) |
| Log Pipeline | `timberio/vector` (0.44.0) |
| Visualization | `grafana/grafana-oss` (11.6.0) |

---

## 14. Integration Guide: External Team (AI-SpamFilter-PMN ↔ MVNO Core)

If you are on the **AI Model Team** developing in the [AI-Filteration-System](https://github.com/AI-SpamFilter-PMN/AI-Filteration-System) repository:

### Interface Contract
Your container model service **MUST** expose an HTTP REST classification endpoint at:
`POST /api/v1/classify` (Listening on `0.0.0.0:8000` inside container network `mvno_net`).

### Contract Payload Schema
* **SMS Classification Request (sent by `telecom-api`)**:
  ```json
  {
    "event_type": "SMS",
    "sender_msisdn": "15551234567",
    "recipient_msisdn": "15557654321",
    "content_text": "Urgent: Claim your free prize now at http://spam.link",
    "timestamp_epoch_ms": 1721590000000
  }
  ```
* **Voice Call Classification Request (sent by `telecom-api`)**:
  ```json
  {
    "event_type": "VOICE_CALL",
    "caller_msisdn": "15551234567",
    "callee_msisdn": "15557654321",
    "content_text": "Transcribed voice audio text from Vosk Java 21 JNI",
    "timestamp_epoch_ms": 1721590000000,
    "call_id": "call-123"
  }
  ```
* **Required JSON Response (expected by `telecom-api`)**:
  ```json
  {
    "allow": false,
    "reason": "Phishing URL detected"
  }
  ```

### Teammate Integration Parameters
* **SMS Client Teammate (Ali — `sms-client`)**:
  - SMPP 3.4 Host & Port: `osmo-smsc:2775` (inside `mvno_net`)
  - SMSC System-ID: `MVNO_SMSC`
  - Primary ESME Account: `mvno-api-route` / password `changeme`
  - Secondary Client ESME Account: `smsclient` / password `password`
  - REST Interception Endpoint: `POST http://telecom-api:8080/api/v1/intercept/sms`
* **Voice Client Teammate (A7med3mar4 — `SipClient`)**:
  - SIP Registrar & Proxy Target: `localhost:5066` on host (`5066:5060/udp`)
  - RTP Media Port Range: `30000-30100/udp` (G.711u PCMU)

### Carrier SLA & Resilience Rules
1. **5.0s Read Timeout**: `telecom-api` enforces a 5-second timeout window. If your model takes $> 5.0\text{s}$, `telecom-api` automatically fails open (`allow: true`). Keep inference latency $\le 500\text{ ms}$.
2. **Circuit Breaker**: If `ai-filter` fails 3 consecutive times, the in-memory circuit breaker opens for 30s, failing open in ~0.1ms.

### Deployment Steps into MVNO Core
1. Package model into container image `mvno-ai-filter:1.0.0`.
2. Attach service `ai-filter` to `mvno_net` network in `docker-compose.yml`.
3. Verify with `make test-sms` and `make test-call`.