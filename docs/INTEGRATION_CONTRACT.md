# MVNO Core — Integration & API Contract (External Repositories)

This document is the **single source of truth** for every public interface the MVNO core exposes
to the three external repositories (`AI-Filteration-System`, `SipClient`, `sms-client`), so their
clients can plug in **without modifying this repo**. The MVNO is the central repo; those
repositories are treated as **read-only external consumers**.

> Principle: MVNO exposes stable interfaces; external clients align to them.
> MVNO never edits external repositories. Gaps are surfaced as *recommendations*, never as edits.

**Flow ordering:**
- **SMS:** the message is classified by the AI filter **first**; an allowed message then proceeds
  through the MVNO gateway and is delivered to the MT recipient (consumer → AI filter → MVNO → MT).
- **Voice:** the **real-time** gate is **metadata-only with fail-open** — if the AI filter is slow or
  down the call passes — and scam/spam is **determined post-call** from the recording/transcript
  (call → MVNO → recording → ASR transcript → `TRANSCRIPT` classification → verdict).

---

## 1. Interfaces MVNO exposes

| Interface | Endpoint / Port | Protocol | Consumed by | Status |
|---|---|---|---|---|
| **SIP registrar/proxy** | `127.0.0.1:5066` (host) → Kamailio `:5060` (container) | UDP/TCP SIP, RFC 3261 + digest auth | `SipClient` | ✅ stable |
| **SMPP SMSC** | `127.0.0.1:2775` → OsmoSMSC | SMPP 3.4 (ESME bind/submit) | `sms-client` | ✅ stable |
| **SMS intercept REST** | `POST /api/v1/intercept/sms` (`mvno-api:8080`, host `8080`) | HTTP JSON + `X-API-Key` | `sms-client` (optional) | ✅ stable |
| **Call intercept REST** | `POST|GET /api/v1/intercept/call` (`mvno-api:8080`) | HTTP JSON + `X-API-Key` | `SipClient` (via Kamailio) | ✅ stable |
| **Subscriber balance REST** | `GET /api/v1/intercept/subscriber/{msisdn}` | HTTP JSON + `X-API-Key` | NOC / external consumers | ✅ stable |
| **AI classifier** | `POST /api/v1/classify` on `ai-filter:8000` (host `8008`) | HTTP JSON — 3 event types (Section 4) | `telecom-api` outbound; drop-in target for `AI-Filteration-System` | ✅ mock-authoritative |
| **Post-call analytics REST** | `POST /api/v1/transcriptions` (`mvno-api:8080`) | HTTP JSON (transcript + biometrics + DTMF) | external clients pushing post-call analytics | ✅ stable (inbound only) |

The inline mock (defined in `docker-compose.yml`) is the **authoritative classifier
for the demo**: it returns `allow:false` / `reason:"Spam (E2E deterministic block)"`
whenever the request body contains the marker `E2E-BLOCK`, else `allow:true`
(`reason:"Clean content"`). The marker works for **all three event types** (SMS content,
VOICE_CALL metadata, TRANSCRIPT text alike) because the mock is event-type agnostic.
The e2e runbook's AI-block cell (Goal 7) asserts this path for SMS. The mock also parses
`Transfer-Encoding: chunked` bodies (Spring `RestClient` sends chunked, without
`Content-Length`); a real FastAPI classifier handles chunked natively and needs no
such workaround.

---

## 2. Gateway Authentication (X-API-Key — Zero-Trust)

All `telecom-api` interception endpoints (`POST /api/v1/intercept/sms`, `GET /api/v1/intercept/call`
— Kamailio callout, `POST /api/v1/intercept/call`, `GET /api/v1/intercept/subscriber/{msisdn}`)
require the header:

```
X-API-Key: mvno-demo-key-2026
```

- Missing or mismatched key → `HTTP 401 Unauthorized`.
- Demo key default from `intercept.api-key` property (env override: `X_API_KEY`).
- Not required for `/actuator/*` health/metrics endpoints (scrape-safe).
- **Scope:** only `/api/v1/intercept/**` is key-protected. `POST /api/v1/classify` (outbound to
  `ai-filter`) and `/actuator/*` are unaffected; SIP (407 digest) and SMPP (ESME credentials)
  authenticate at their own protocol layers.
- **Kamailio callout** (voice path): `GET /api/v1/intercept/call?caller=<$fU>&callee=<$rU>` with the
  `X-API-Key` header (see `kamailio.cfg` `route[INTERCEPT]`, `http_client_query`). Caller/callee are
  E.164 MSISDNs; the gateway response is `{ "allow": boolean, "reason": "string" }` — `allow:false`
  → Kamailio rejects the call with `403 Call Intercepted / Blocked`.

---

## 3. API Contract & Payload Schema (`POST /api/v1/classify`)

`telecom-api` proxies real-time SMS content, voice-call metadata, and post-call transcripts to the
AI classifier. Payload shape is **event-typed** — SMS, VOICE_CALL, and TRANSCRIPT carry different
fields (verified against `AiFilterService.java`).

**Transport**: `POST` with header `Content-Type: application/json`. The inline demo mock is
header-tolerant (for `curl -d` convenience), but a production classifier MUST require the
header and reject other types with `415 Unsupported Media Type`.

**SMS event** (`event_type: "SMS"`):
```json
{
  "event_type": "SMS",
  "sender_msisdn": "15551234567",
  "recipient_msisdn": "15559876543",
  "content_text": "Urgent: Claim your free prize now at http://spam.link",
  "timestamp_epoch_ms": 1721590000000
}
```

**Voice Call event** (`event_type: "VOICE_CALL"`):
```json
{
  "event_type": "VOICE_CALL",
  "caller_msisdn": "15551234567",
  "callee_msisdn": "15557654321",
  "call_id": "call-123",
  "timestamp_epoch_ms": 1721590000000
}
```

**Transcript event** (`event_type: "TRANSCRIPT"` — post-call, sent by `NativeVoskService` after ASR):
```json
{
  "event_type": "TRANSCRIPT",
  "call_id": "call-1785097956%40127.0.0.1-464274ce81646346",
  "transcript": "Hello, this is your bank. Please confirm your pin number.",
  "timestamp_epoch_ms": 1721590000000
}
```

* **`event_type`**: `"SMS"` | `"VOICE_CALL"` | `"TRANSCRIPT"`.
* **`sender_msisdn`** / **`recipient_msisdn`** (SMS only): originating / destination E.164 number.
* **`content_text`** (SMS only): raw SMS text. Not present on other events.
* **`caller_msisdn`** / **`callee_msisdn`** (VOICE_CALL only): originating / destination E.164 number.
* **`call_id`** (VOICE_CALL / TRANSCRIPT only): SIP Call-ID (VOICE_CALL) or recording identifier
  (TRANSCRIPT). rtpengine spool files carry no SIP Call-ID in the filename
  (`call-<epoch>%<host>-<hash>.wav`), so the **filename stem is the TRANSCRIPT `call_id`**. Never sent for SMS.
* **`transcript`** (TRANSCRIPT only): Vosk ASR transcribed speech text. Voice transcriptions are NOT
  included in SMS/VOICE_CALL payloads.
* **`timestamp_epoch_ms`**: event timestamp in epoch milliseconds.

**Response payload (expected by `telecom-api` from `ai-filter`):**
```json
{
  "allow": false,
  "reason": "High-probability phishing link detected"
}
```

* **`allow`**: `true` if call/SMS setup is allowed (or transcript is clean); `false` to block.
* **`reason`**: human-readable classification explanation for NOC audit logging.

---

## 4. SLA Constraints & Fail-Open Behavior

### 1. Split-Timeout Windows
- **`AI_FILTER_CONNECT_TIMEOUT_SECONDS`**: 1s connect timeout.
- **`AI_FILTER_READ_TIMEOUT_SECONDS`**: 5s read timeout to accommodate CPU model inference latency.

### 2. Carrier SLA Fallback (Fail-Open)
If `ai-filter:8000` is offline, times out (> 5.0s), or returns an HTTP 5xx error, `telecom-api`
automatically executes **Carrier SLA Fallback**:
```json
{
  "allow": true,
  "reason": "AI filter unreachable — SLA allow"
}
```
*SMS/Calls will be allowed through to prevent carrier service outages.* Post-call TRANSCRIPT
classification uses the same fail-open policy — a transcript verdict failure never stalls the
media spool loop.

**Observability:** every fail-open increments `mvno_ai_failopen_total{reason}` (Micrometer,
exported at `/actuator/prometheus`, scraped into VictoriaMetrics; Grafana alert
`MVNO AI Fail-Open SLA Rate`). `reason` ∈ `unreachable` | `empty_response` | `internal` |
`circuit_open` — the SLA contract is instrumented end-to-end. Transcript verdicts additionally
export `mvno_vosk_classified_total` and `mvno_vosk_blocked_total`.

### 3. Environment Variables Summary
In `docker-compose.yml` / `application.yml`:
```yaml
AI_FILTER_URL: http://ai-filter:8000/api/v1/classify
AI_FILTER_CONNECT_TIMEOUT_SECONDS: 1
AI_FILTER_READ_TIMEOUT_SECONDS: 5
```

---

## 5. Per-repository integration notes (read-only — changes on the external side are made there)

> Verified against cloned sources on 2026-08-03 (read-only clones of
> `github.com/AI-SpamFilter-PMN/sms-client` and `.../SipClient`); findings below
> marked ✅-verified or ⚠-mismatch. MVNO still never edits external repositories.

### SipClient (`com.sipclient.sip.config.SipConfig`) — ✅ verified
- `SipConfig` hardcodes `SERVER_PORT = 5060`, `LOCAL_PORT = 5070` (confirmed in
  source). Ships targeting `SERVER_PORT = 5060`, local `127.0.0.1:5070`.
- **MVNO Kamailio host port is `5066`** (canonical). Host `5060` is occupied by a host-level
  Asterisk (see `docs/ENVIRONMENT_MATRIX.md` Section 3) — the optional `MVNO_PUBLISH_5060` extra
  publish is **default-off and blocked on this host**.
- **Recommendation to the consuming client (not an MVNO edit):** set the SIP server port to `5066`
  (or make it configurable) so the unmodified client reaches Kamailio.
- **SIP INVITE Authentication (407 Digest):** Kamailio challenges unauthenticated `INVITE` with
  `407 Proxy Authentication Required`. Clients MUST handle the `Proxy-Authenticate: Digest`
  challenge and retry with an `Authorization: Digest` header using their subscriber-table
  credentials (`username: MSISDN`, realm `localhost`, password `testpass`). Applies to REGISTER and
  INVITE alike.
- **RTP Media Relay:** RTPEngine ports `30000-30100/udp` (G.711u PCMU codec supported).
- **Codec:** configure the client for **PCMU (G.711u, payload type 0) only** — the relay does not
  transcode; PCMA/opus negotiations fail media.
- **Blocked calls:** zero-balance / EIR-fraud / AI-blocked calls are rejected with
  `SIP/2.0 403 Forbidden` — treat 403 as a terminal call failure (no retry loop).
- **Firewall:** open UDP `30000-30100` (RTP relay range) and UDP `5066` (SIP) between client host
  and MVNO host; the client's own RTP socket must be reachable (see `fix_nated_contact()` in
  `configs/kamailio/kamailio.cfg`).

### sms-client (`src/main/resources/application.properties`) — ✅ verified
- `smpp.host=127.0.0.1`, `smpp.port=2775`, `smpp.systemId=smsclient`, `smpp.password=password`
  → **matches MVNO's published SMPP + the `esme smsclient` route in `osmo-smsc.cfg`** ✅.
- `ai.classify.url=http://localhost:5000/classify` — ⚠ **mismatch confirmed in
  source**: matches **no** MVNO endpoint (MVNO mock is `ai-filter:8000/api/v1/classify`;
  `AI-Filteration-System` is `:8000/api/filter-sms`).
  → **Exact replacement value** (co-hosted on `mvno_net`): `http://mvno-ai-filter:8000/api/v1/classify`
  (from a non-containerized host: `http://localhost:8008/api/v1/classify`). This is **optional
  redundancy** — MVNO enforces allow/block AFTER SMPP submission via the gateway, so client-side
  classification is not required for the demo.
- `server.port=8080` ⚠ overlaps `telecom-api`'s `8080` if co-hosted — run on a different host/port
  (e.g. `server.port=8081`).
- `sms.blockSpam=false` default: spam is NOT blocked client-side; MVNO policy gateway still enforces.
- **SMPP credentials:** SMSC System-ID `MVNO_SMSC`; primary ESME account `mvno-api-route` /
  password `changeme`; secondary client ESME account `smsclient` / password `password`.
- **REST Interception (optional):** `POST http://telecom-api:8080/api/v1/intercept/sms` with
  `X-API-Key: mvno-demo-key-2026`; response `{ "allow": boolean, "reason": "string" }`.

### AI-Filteration-System (`ai-model.py`) — endpoint documented, repo private (not verifiable)
- FastAPI at `:8000/api/filter-sms`, requires `API_KEY` + `MODEL_ID` (routes to agentrouter.org).
- For the MVNO demo the **inline `mvno-ai-filter` mock is authoritative** and now
  implements a **deterministic AI-block rule** (`E2E-BLOCK` marker → `allow:false`),
  added config-only in `docker-compose.yml` and **verified end-to-end** by the Goal 7
  `e2e_runbook.sh` AI-block cell (Kamailio 403 + `mvno_sms_blocked_total` increment,
  two consecutive green runs). No external classifier or API key is required.
- **Drop-in criteria** (to replace the mock in the live demo):
  - Must expose `POST /api/v1/classify` on `0.0.0.0:8000` inside the `mvno_net` network.
  - Must accept **all three event types** (Section 3) and return `{ "allow": boolean, "reason": "string" }`.
  - Must classify within the 5s read window (target ≤ 500ms per the SLA contract).
  - Package as container image `mvno-ai-filter:1.0.0`; attach to `mvno_net` in `docker-compose.yml`.
  - Verify with `make test-sms` and `make test-call`.
- **Deterministic fallback layer (REQUIRED for the demo and the gates):**
  - The e2e Goal-7 AI-block cell asserts the `E2E-BLOCK` marker → `allow:false` and the demo's
    post-call scam-block story asserts phishing-keyword blocking on `TRANSCRIPT` events
    (word-boundary, lowercase: `won`, `prize`, `claim`, `free`, `urgent`, `account`, `blocked`,
    `confirm` — tuned to Vosk small-model ASR output, e.g. "You have won a prize, call us now" →
    Vosk hears `you have won an prize called us out`).
  - The replacement MUST keep an equivalent deterministic rule layer (marker + keyword list) OR
    prove the model blocks those exact inputs — otherwise `e2e_runbook.sh` and `demo_runbook.sh`
    check 9 break and the demo's blocked-call story is unverifiable.
- **TRANSCRIPT events are post-call analytics only**: verdicts never retro-block an in-flight call;
    they increment `mvno_vosk_blocked_total` and appear in the mvno-api log.

---

## 6. Optional `MVNO_PUBLISH_5060` (default-off, env-gated)

- A `SipClient` instance that hardcodes `5060` can be accommodated **only on hosts where UDP 5060
  is free** by publishing an extra `5060:5060`. This is **default-off** and **blocked on this host**
  (Asterisk owns `0.0.0.0:5060`). Enable via compose env when the host is clean.
- `scripts/preflight.sh` checks `ss -lun | grep :5060` and warns loudly if occupied.

---

## 7. MVNO-side stability guarantee

MVNO keeps these seams stable across changes so external clients keep working without edits:
- `POST /api/v1/intercept/sms`, `POST|GET /api/v1/intercept/call` request/response schemas.
- `POST /api/v1/classify` with the three event types (SMS, VOICE_CALL, TRANSCRIPT) + `{allow, reason}`.
- SMPP `2775` + the `esme smsclient`/`esme mvno-api-route` routes.
- SIP `5066` host port + digest `subscriber` table credentials (`testpass`).
- `POST /api/v1/transcriptions` inbound schema (transcript + biometrics + DTMF).

Any breaking change to these is a **coordinated, versioned contract change** communicated to the consuming repositories.

---

## 8. Partner handoff package (files to share with each repository)

### AI-Filteration-System (classifier provider)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` (this file) | Section 3 payload schemas (3 event types), Section 4 SLA/fail-open |
| `docker-compose.yml` service `ai-filter` (lines ~543) | reference mock implementation to replace (incl. deterministic keyword/E2E-BLOCK fallback layer) |
| `telecom-api/.../filter/AiFilterService.java` | exact outbound call semantics (`AI_FILTER_URL`, timeouts, circuit breaker) |
| `telecom-api/src/test/java/.../AiFilterSlaTimeoutTest.java` | SLA behavior the model must satisfy |
| `scripts/testing/e2e_runbook.sh` Goal 7 cell | the AI-block assertion the model must keep green |

**Prove your integration with**: `make test-sms` + `make test-call`; `./scripts/testing/e2e_runbook.sh` (Goal 7 AI-block cell must stay green — requires your container to keep the deterministic `E2E-BLOCK`/keyword rules); `./scripts/testing/demo_runbook.sh` check 9b (scam speech → `allow:false` + `mvno_vosk_blocked_total` increment).

### SipClient (voice user agent)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` Section 1, Section 5 (SipClient), Section 6 | ports, digest auth, PCMU-only codec, 403 semantics, RTP range, `MVNO_PUBLISH_5060` |
| `docs/ENVIRONMENT_MATRIX.md` Section 3 | why host `5060` is blocked (Asterisk) |
| `configs/kamailio/kamailio.cfg` `route[INTERCEPT]` | call-intercept callout behavior |
| `docs/MANUAL_TESTING_GUIDE.md` voice flows | end-to-end call + RTP + recording verification steps (Flow E, T6/T7/T8) |
| `scripts/testing/sip_traffic_sim.py` | reference UA — your client must reproduce its REGISTER/407→digest→INVITE→RTP behavior |

**Prove your integration with**: `./scripts/testing/demo_runbook.sh` check 5 (replace the sim caller with your client: REGISTER 200 OK, call answered, `rtpengine_bytes_total` moves) and check 6 (your client must surface the 403 Forbidden from a zero-balance call). Also Flow E T6/T7 for the full media dialog.

### sms-client (SMPP ESME)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` Section 1, Section 5 (sms-client) | SMPP `2775`, `MVNO_SMSC`, ESME accounts, `ai.classify.url` replacement value, intercept REST |
| `configs/osmocom/osmo-smsc.cfg` | the `esme smsclient` / `esme mvno-api-route` routes |
| `docs/MANUAL_TESTING_GUIDE.md` SMS flows | 2G/5G + IP-SM-GW delivery verification |
| `scripts/testing/e2e_runbook.sh` | 5-cell SMS matrix (2G→2G, 2G→5G, 5G→2G, 5G→5G, AI-block) |
| `scripts/testing/send_smpp_sms.py` | reference ESME — your client must reproduce BIND_TRANSCEIVER + SUBMIT_SM against `127.0.0.1:2775` |

**Prove your integration with**: `./scripts/testing/demo_runbook.sh` check 10 (binary BIND_TRANSCEIVER) + check 10b (SUBMIT_SM ESME_ROK) — replace the harness with your client; `./scripts/testing/e2e_runbook.sh` (all 5 cells, incl. the AI-block 403 path).
