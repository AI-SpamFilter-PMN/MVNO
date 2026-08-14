# MVNO Core — Team Onboarding Guide
> Abbreviations: **docs/GLOSSARY.md** — single source of truth

## 1. Project Identity

This repository contains a **complete Mobile Virtual Network Operator (MVNO) 5G SA Core with real-time interception gateway**. It combines a standards-compliant 5G Standalone core (Open5GS + UERANSIM), an Osmocom-based cellular stack (HLR/MSC/SMSC), a Spring Boot interception gateway with native Vosk ASR (Automatic Speech Recognition), and an AI spam filter integration point — all orchestrated via rootless Podman/Docker Compose. It is **not** a production billing platform, a full IMS core, or a managed SaaS — it's a developer-grade stack for building and testing spam/voice interception logic.

**Recommended start**: run `docs/LIVE_DEMO.md` — the from-zero live demo (S1–S10): a complete raw-shell walkthrough (no Python, no scripts) of the live stack: baresip voice call, recording → Vosk spam verdict, and all five Short Message Service (SMS) paths, ending with the automated demo/e2e gates. The full terminal-by-terminal reference (scripted variants, troubleshooting, certification log) is `docs/TESTING_REFERENCE.md`.

## 2. Architecture Overview

```
┌───────────────────┐  ┌──────────────────────┐  ┌──────────────────┐  ┌─────────────┐
│ VOICE PATH        │  │                      │  │                  │  │             │
│ SipClient UA      │─▶│ Kamailio SIP Proxy   │─▶│ Telecom Gateway  │─▶│ AI Spam     │
│ (SIP 5060)        │  │ (407 digest + 403)   │  │ (Spring Boot:    │  │ Filter      │
└───────────────────┘  └──────────────────────┘  │  OCS · EIR · SLA)│  │ (External)  │
┌───────────────────┐  ┌──────────────────────┐  └────────┬─────────┘  └─────────────┘
│ SMS PATH          │  │                      │           │
│ sms-client ESME   │─▶│ OsmoSMSC (SMPP 2775) │─▶  POST /intercept/* (X-API-Key)
│ (SMPP 3.4)        │  │                      │
└───────────────────┘  └──────────────────────┘
┌───────────────────┐  ┌──────────────────────┐
│ 5G RADIO TRACK    │  │ Open5GS 5GC          │   (registration-only — SMS-over-NAS on roadmap)
│ UERANSIM gNB+3UEs │─▶│ AMF/SMF/UPF/NRF      │
└───────────────────┘  └──────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ OBSERVABILITY — Vector → VictoriaMetrics → Grafana NOC          │
│ (Unified + VictoriaMetrics System dashboards · 4 alert rules)   │
└────────────────────────────────────────────────────────────────┘
```

**Components:**
- **5G SA Core**: Open5GS 10 NFs (NRF, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) + UERANSIM gNB + 3 UEs (User Equipment)
- **Osmocom Stack**: HLR (GSUP) + SMSC (Short Message Peer-to-Peer (SMPP) 3.4) via `osmo-hlr` + `osmo-smsc` containers (the `osmo-msc` binary runs in SMSC mode)
- **Interception Gateway**: Kamailio Session Initiation Protocol (SIP) registrar/proxy → `rtpengine` media fork → Vosk ASR (native JNI) → Spring Boot gateway (Java 21, virtual threads)
- **AI Spam Filter**: External REST service at `http://ai-filter:8000/api/v1/classify`
- **Observability**: Vector (stdout log driver) → VictoriaMetrics (metrics TSDB) → Grafana (2 dashboards: Unified Network Operations Center (NOC) + VictoriaMetrics System NOC)

**Diagrams:** `docs/architecture_flow.svg`, `docs/ims_voice_call_flow.svg`, `docs/sms_interception_flow.svg`

---

## 3. Prerequisites (Per OS)

The **recommended** on-ramp is the single-command deployer (auto-installs missing
packages, loads SCTP, pulls images from Docker Hub, init-db, up, self-heals):

```bash
./scripts/deploy.sh            # full bring-up; try --check first (read-only)
```

Manual equivalents:

| Distro | Command |
|--------|---------|
| Ubuntu/Debian | `apt install podman docker-compose-v2 sqlite3 lksctp-tools espeak-ng ffmpeg pipewire-pulse` |
| Fedora/RHEL | `dnf install podman podman-compose sqlite3 lksctp-tools espeak-ng ffmpeg pipewire-pulse` |
| Arch/CachyOS | `pacman -S podman docker-compose sqlite3 lksctp-tools espeak-ng ffmpeg pipewire-pulse` |
| **All** | `sudo modprobe sctp` (verify: `lsmod \| grep sctp`) |

> **UFW (Ubuntu default firewall) — the #1 silent phone-media killer:** with UFW
> active, SIP (5060) passes but the phone's RTP media (UDP 10000-20000) is
> silently dropped — calls ring but carry no audio. Allow both:
> `sudo ufw allow 5060/udp && sudo ufw allow 10000:20000/udp`. `preflight.sh`
> detects this and warns.

> **Pulse/PipeWire (live-mic demo legs):** the baresip rig captures the real
> laptop mic via the host Pulse daemon. `pipewire-pulse` (or `pulseaudio`) must
> be **running** and `$XDG_RUNTIME_DIR/pulse/native` must exist. The compose
> baresip services default to uid-1000 paths; if your UID differs, export
> `PULSE_SOCK` / `PULSE_DIR` / `PULSE_COOKIE` before `demo_call.sh setup`
> (the script exports them for you from your own runtime dir).

> `espeak-ng` + `ffmpeg` are used by `demo_call.sh setup` to synthesize the
> canned callee scam phrase ("You have won a prize, call us now or your account
> will be closed") into an 8 kHz WAV. `live_demo.sh` then proves the REAL path
> (baresip → Kamailio → RTPEngine → pcap → live_tap → Vosk) end-to-end — no TTS in
> the 9b verdict; it re-arches the live recorded call. `deploy.sh` installs them.

> **Note**: SCTP kernel module is mandatory for 5G NGAP (gNB ↔ AMF). Without it, gNB never connects.
> **Image source**: the 9 custom images (`mvno-*`, incl. `mvno-baresip:1.1.0` rig)
> are **public on Docker Hub**
> (`docker.io/5attab007/mvno-*`) — `./scripts/pull-images.sh` pulls + retags them.
> Vendor images pull from their own public namespaces. `deploy.sh` does this for you;
> use `./scripts/bootstrap.sh` + `./scripts/load-offline.sh` only for air-gapped setups.

> **When are images re-published?** Only code that is **baked into an image** changes its Docker Hub
> artifact. The `ip-sm-gw` bridge (`scripts/ip_sm_gw.py`) and the `ai-filter` mock run from a
> **mounted volume / inline compose code** on stock `python:3.11-alpine` — their fixes never require
> an image push. Rebuild + re-push the published images **only** when `telecom-api/` source, a
> `configs/*/Dockerfile*`, or the 2G image Dockerfiles change.

After such a change, from repo root:

```bash
make rebuild                              # offline local rebuild (init-db + up --build)
podman push docker.io/5attab007/mvno-telecom-api:1.0.0   # push each changed image, e.g.:
# repeat for the other changed images (mvno-kamailio, mvno-open5gs, …, as applicable)
```


---

## 4. Quickstart (Copy-Paste Ready)

**One command (recommended):**

```bash
git clone https://github.com/AI-SpamFilter-PMN/MVNO.git
cd MVNO
./scripts/deploy.sh      # installs deps, pulls images from Docker Hub, init-db, up, self-heals
```

**Step-by-step (what deploy.sh wraps):**

```bash
./scripts/pull-images.sh # pull the 9 custom images from docker.io/5attab007/mvno-*
make init-db             # creates SQLite WAL DBs + seeds test subscribers
make up                  # offline-first launch (37 services: 34 core + 2 baresip rig + 1 Asterisk sidecar)
make seed-mongo          # Open5GS 5G subscribers — AFTER up (execs into mongodb)
make test                # runs test-vty + test-api + test-sms + test-call
```

(One-command cold start: `make bootstrap` ≡ the three `make` steps above.)

---

## 5. Key Make Targets

| Target | Purpose |
|--------|---------|
| `make up` | Start container stack (offline-first, uses pre-loaded images; 37 services: 34 core + 2 baresip rig + 1 Asterisk sidecar) |
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

The full request/response schemas live in **`docs/INTEGRATION_CONTRACT.md` Section 3** — one contract with
three event types: `SMS`, `VOICE_CALL`, and `TRANSCRIPT` (post-call ASR output). The response is
always `{ "allow": boolean, "reason": "string" }`.

**SLA:** 5s read timeout → fail-open (`allow: true`). Circuit breaker: 3 consecutive failures → 30s
fast fail-open (~0.1ms). Full SLA/fail-open/env-variable spec: `docs/INTEGRATION_CONTRACT.md` Section 4.

**Current mock:** `ai-filter` returns `allow:false` (reason `"Spam (E2E deterministic block)"`) when
the payload contains the `E2E-BLOCK` marker, else `allow:true` (`"Clean content"`) — the marker
works for all three event types. Drop-in replace the container with the real
`AI-Filteration-System` model for live spam detection (drop-in criteria:
`docs/INTEGRATION_CONTRACT.md` Section 5).

**Voice post-call leg (supervisor flow):** recorded calls are transcribed in-process by Vosk ASR;
the transcript is then POSTed to the AI filter as a `TRANSCRIPT` event
(`AiFilterService.classifyTranscript`) and the verdict is logged + exported as
`mvno_vosk_classified_total` / `mvno_vosk_blocked_total`. Fail-open: a transcript verdict failure
never stalls the spool loop.

---

### 6a. Layered Interception Pipeline

| Layer | Check | Block Condition |
|-------|-------|-----------------|
| 1. Prepaid OCS | SQLite balance ≤ 0 | `allow: false, "Prepaid balance exhausted"` |
| 2. Equipment Identity Register (EIR) | IMEI→MSISDN binding >3 swaps/10min | `allow: false, "EIR: SIM swap detected"` |
| 3. AI Filter | External model classification | `allow: false, "AI: spam detected"` |

**End-to-end flow narrative:**
- **SMS:** The message is classified by the **AI filter first**; an allowed message then proceeds
  through the MVNO gateway and is **delivered to the MT** recipient (consumer → AI filter →
  MVNO/REST → MT).
- **Voice:** The **real-time** gate is **metadata-only with fail-open** — if the AI filter is slow or
  down, the call **passes** — and whether it was scam/spam is **determined post-call** from the
  recording/transcript (see Section 6d / Vosk ASR).

---

## 7. Configuration — Key File Reference

| File | Why |
|------|-----|
| `configs/osmocom/osmo-smsc.cfg` | `remote-ip 10.89.0.45` — static IP guaranteed by compose |
| `state/kamailio/kamailio.db` | Auto-generated by `make init-db` (WAL mode) |
## 7. 3GPP Group Calls, Conference Factory & In-Call Handling

The MVNO stack supports carrier-grade **3GPP Supplementary Services** (TS 24.615 / TS 24.610 / RFC 4579):

| 3GPP Feature | Standard / Trigger | Network Handling |
|---|---|---|
| **Merge to Conference** | Linphone "Merge Calls" button | Handset sends SIP INVITE to `sip:conf-factory@<HOST-LAN-IP>:5060`. Kamailio & Asterisk ConfBridge mix all 3 legs in real-time. |
| **Call Waiting (CW)** | 2nd call arrives while busy | Handset alerts with CW tone; operator can Accept 2nd call and put 1st call on Hold (`a=sendonly`). |
| **Quick-Reply Rejection** | User taps "Quick Reply" on incoming call | Handset sends SMS ("In a meeting, call back later") + terminates with `SIP 486 Busy Here`. |
| **Voicemail Main** | Dial `8XXX` (e.g. `8100`) | Direct access to Asterisk Voicemail box to record greetings / check messages. |

Automated verification:
```bash
python3 scripts/testing/call_waiting_conference_demo.py
```

---

## 8. Development Workflow Verification

| Command | Expected Output |
|---------|----------|
| `make test-api` | `{"status":"UP"}` + subscriber JSON |
| `make test-vty` | `✓ HLR subscriber found` + `✓ Primary SMPP ESME configured` + `✓ Secondary client SMPP ESME configured` |
| `make test-sms` | `allow: true, "Clean content"` |
| `make test-call` | `allow: false, "EIR: SIM swap detected"` (test IMEI) |
| `make test` | All 4 pass |
| `cd telecom-api && ./mvnw test` | 26/26 pass (includes SLA + circuit breaker + distinct EIR + GET intercept + API-key interceptor + Vosk verdict tests) |
| `bash scripts/check-glossary.sh` | exit 0: `✓ 0 uncovered` (glossary lint gate) |

---

## 9. Observability

| Tool | URL | Purpose |
|------|-----|---------|
| Grafana | `http://localhost:3000` (admin/admin) | Dashboards: MVNO NOC — Unified, MVNO VictoriaMetrics System NOC (auto-provisioned, hot-reload; 4 alert rules) |
| VictoriaMetrics | `http://localhost:8428` | Raw PromQL queries |
| vmagent | `http://localhost:8429` | Scrape config |
| Vector | Internal | Log pipeline (console stdout driver; VictoriaLogs on Roadmap) |

**Key metrics (12 families):** `mvno_sms_requests_total`, `mvno_sms_blocked_total`, `mvno_call_requests_total`, `mvno_call_blocked_total`, `mvno_call_blocked_eir_total`, `mvno_subscriber_lookups_total`, `mvno_eir_sim_swap_detected_total`, `mvno_eir_cache_size` (gauge), `mvno_vosk_transcriptions_total`, `mvno_vosk_decode_errors_total`, `mvno_vosk_model_ready` (gauge 0/1), `mvno_ai_failopen_total{reason}` — lazily registered: 11 families export at idle; `mvno_ai_failopen_total` appears only after the first SLA fail-open.

---

## 10. Known Limitations (Demo Day Risks)

| Area | Limitation |
|------|------------|
| **Vosk ASR** | English-only small model (50MB). Post-call only. ~10-15% WER. No Arabic. |
| **AI Filter Mock** | Returns `allow:false` on the `E2E-BLOCK` marker (deterministic), else `allow:true`. Swap in the real `AI-Filteration-System` model for live spam detection. |
| **SIP Testing** | `make test-call` uses HTTP POST; real SIP covered by `scripts/testing/sip_traffic_sim.py` (REGISTER + 407 digest challenge → INVITE handshake, used by live_demo items 5/6). No SIPp scenario included. |
| **5G Radio Path** | 3 UERANSIM UEs registered on the AMF with a **verified UL+DL user-plane data path** (UE tun → N3 GTP-U → UPF ogstun). After any UERANSIM UE recreate, re-add the UE route (`ip route add 10.45.0.1 dev uesimtun0`) and recreate the trio atomically (see `docs/ISSUES.md` S7.4). **No SMS-over-NAS / VoNR over radio** — voice and SMS are external-path demos (SipClient / sms-client); SMS-over-NAS is on the roadmap. |
| **SCTP Kernel** | `modprobe sctp` required on host. Fails silently if missing (gNB↔AMF never connects). |
| **RTPEngine (rtpengine media proxy) Kernel** | Runs in userspace mode (kernel module not required). |
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
| UL data plane dead after gNB recreate | Stale NGAP contexts; gNB silently swallows PDU Session Resource Setup | Recreate the **whole UERANSIM trio** (`podman compose up -d --force-recreate ueransim-gnb ueransim-ue-1 ueransim-ue-2 ueransim-ue-3`), never a single container — `docs/ISSUES.md` S7.4 |
| UE can't reach `10.45.0.1` | UE default route missing | `podman exec mvno-ueransim-ue-N sh -c 'ip route add 10.45.0.1 dev uesimtun0'` |
| NFs de-register from NRF every ~30s | Rebuilt Open5GS from source | Use the layered Dockerfile on `mvno-open5gs:2.8.0-base` — never rebuild from source (`docs/ISSUES.md` S5.6) |
| 5G-path SIP times out on first packet | Neighbor-resolution warm-up after UPF/bridge restarts | Re-run the simulator — subsequent exchanges are immediate |
| UE can't reach bridge services via 5G | SNAT rule missing (UPF recreated) | Entrypoint installs it idempotently; verify `podman exec mvno-upf iptables -t nat -L POSTROUTING -n` |
| Phone call rings but NO audio / `[UFW BLOCK]` in kernel log | Ubuntu UFW silently drops RTP media (UDP 10000-20000) | `sudo ufw allow 5060/udp && sudo ufw allow 10000:20000/udp` (preflight warns) |
| baresip no mic / `pulse: ... failed` in `podman logs baresip-tx` | Host Pulse daemon not running, or wrong socket path | Start `pipewire-pulse`/`pulseaudio`; export `PULSE_SOCK`/`PULSE_DIR`/`PULSE_COOKIE` for a non-uid-1000 user, then `demo_call.sh setup` |
| Stale baresip registrations survive `make down` | baresip containers left over from an old raw-`podman run` lifecycle | Run `podman compose up -d baresip-rx baresip-tx` (now compose-managed); `make clean` removes them |

---

## 12. Key Files to Read Next

| File | Why |
|------|-----|
| `docs/deployment_guide.md` | Full ops runbook, configs, Issue 8.x log |
| `docs/INTEGRATION_CONTRACT.md` | Single contract: interfaces + API payload schemas (SMS/VOICE_CALL/TRANSCRIPT) + SLA + per-repo integration + partner handoff |
| `docs/partner/` | **Ready-to-paste integration docs for teammate repos** (`sms-client`, `SipClient`, `Filteration-System`) + `docs/filteration-system-handoff.md` — share these when integrating across the org |
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
| Metrics TSDB | `victoriametrics/victoria-metrics` (v1.147.0) |
| Log Pipeline | `timberio/vector` (0.44.0) |
| Visualization | `grafana/grafana-oss` (11.6.0) |

---

## 14. Integration Guide: External Team (AI-SpamFilter-PMN ↔ MVNO Core)

### Partner Repos & Roles (at a glance)

| Repository | Role | Interface it consumes | MVNO side | Status |
|---|---|---|---|---|
| [`SipClient`](https://github.com/AI-SpamFilter-PMN/SipClient) | Voice UA | SIP `localhost:5060` (host → Kamailio `:5060`), 407 digest | Kamailio registrar/proxy | ✅ stable |
| [`sms-client`](https://github.com/AI-SpamFilter-PMN/sms-client) | SMS ESME | SMPP 3.4 `osmo-smsc:2775`, ESME `smsclient` | OsmoSMSC (SMSC) | ✅ stable |
| [`AI-Filteration-System`](https://github.com/AI-SpamFilter-PMN/AI-Filteration-System) | Classifier | `POST /api/v1/classify` | `telecom-api` (SLA 5s + circuit breaker) | mock-authoritative |

Authoritative per-repository parameters & verified source findings live in **`docs/INTEGRATION_CONTRACT.md`** —
that is the single source of truth for repository-side values and required changes (e.g. SipClient's
`SERVER_PORT` configurable via `sip.properties` (default 5060), sms-client's `ai.classify.url` mismatch), and for the **`/api/v1/classify`
payload schemas (SMS / VOICE_CALL / TRANSCRIPT)**, X-API-Key auth, SLA/fail-open rules, and the
partner handoff file list (contract Section 8). The subsections below summarize it; maintainers of all
three repositories should read the contract file.

If you are on the **AI Model Team** developing in the [AI-Filteration-System](https://github.com/AI-SpamFilter-PMN/AI-Filteration-System) repository:

### Interface Contract
Your container model service **MUST** expose an HTTP REST classification endpoint at:
`POST /api/v1/classify` (Listening on `0.0.0.0:8000` inside container network `mvno_net`), accepting
**all three event types** — `SMS`, `VOICE_CALL`, and `TRANSCRIPT` (post-call ASR output) — and
returning `{ "allow": boolean, "reason": "string" }`. Full JSON schemas:
`docs/INTEGRATION_CONTRACT.md` Section 3 (authoritative copy).

### Contract Payload Schema
* **SMS Classification Request (sent by `telecom-api`)**:
  ```json
  {
    "event_type": "SMS",
    "sender_msisdn": "15551234567",
    "recipient_msisdn": "15559876543",
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
    "call_id": "call-123",
    "timestamp_epoch_ms": 1721590000000
  }
  ```
* **Transcript Classification Request (sent by `NativeVoskService` post-call)**:
  ```json
  {
    "event_type": "TRANSCRIPT",
    "call_id": "call-1785097956%40127.0.0.1-464274ce81646346",
    "transcript": "Hello, this is your bank. Please confirm your pin number.",
    "timestamp_epoch_ms": 1721590000000
  }
  ```
* **Required JSON Response (expected by `telecom-api`, all three event types)**:
  ```json
  {
    "allow": false,
    "reason": "Phishing URL detected"
  }
  ```

### Integration Parameters
* **SMS Client (`sms-client`)**:
  - SMPP 3.4 Host & Port: `osmo-smsc:2775` (inside `mvno_net`)
  - SMSC System-ID: `MVNO_SMSC`
  - Primary ESME (External Short Message Entity) Account: `mvno-api-route` / password `changeme`
  - Secondary Client ESME Account: `smsclient` / password `password`
  - REST Interception Endpoint: `POST http://telecom-api:8080/api/v1/intercept/sms` — **requires header `X-API-Key: mvno-demo-key-2026`** (missing/mismatched key → `401 Unauthorized`; demo key via env `X_API_KEY`)
* **Voice Client (`SipClient`)**:
  - SIP Registrar & Proxy Target: `localhost:5060` on host (`5060:5060/udp`)
  - RTP Media Port Range: `10000-20000/udp` (G.711u PCMU)
  - SIP INVITE Authentication: `INVITE` is challenged with `407 Proxy Authentication Required` (digest, realm `localhost`) — retry with `Authorization: Digest` using your REGISTER credentials

### Carrier SLA & Resilience Rules
1. **5.0s Read Timeout**: `telecom-api` enforces a 5-second timeout window. If your model takes $> 5.0\text{s}$, `telecom-api` automatically fails open (`allow: true`). Keep inference latency $\le 500\text{ ms}$.
2. **Circuit Breaker**: If `ai-filter` fails 3 consecutive times, the in-memory circuit breaker opens for 30s, failing open in ~0.1ms.

### Deployment Steps into MVNO Core
1. Package model into container image `mvno-ai-filter:1.0.0`.
2. Attach service `ai-filter` to `mvno_net` network in `docker-compose.yml`.
3. Verify with `make test-sms` and `make test-call`.