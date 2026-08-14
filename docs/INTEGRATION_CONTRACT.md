# MVNO Core — Integration & API Contract (External Repositories)

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
This document is the **single source of truth** for every public interface the MVNO core exposes
to the external repositories (`Filteration-System` [Spring Boot decider], `SipClient`,
`sms-client`, `admin-client` [Neon DB UI]), so their clients can plug in **without modifying
this repo**. The MVNO is the central repo; those repositories are treated as **read-only
external consumers**. (`AI-Filteration-System` — the archived Python reference scorer — is
reference-only per the handoff doc and is not an active external consumer.)

> Principle: MVNO exposes stable interfaces; external clients align to them.
> MVNO never edits external repositories. Gaps are surfaced as *recommendations*, never as edits.

> **Contract: v1.2** — verified 2026-08-09 against MVNO `main @ 342dcb7`,
> `sms-client` `origin/main @ 1a388af` (refactored), `SipClient` `main`
> (initialization milestone), and last-known `Filteration-System` state (private
> — re-verify). On any conflict between this file and another doc, **this file
> wins**; if it conflicts with the live stack, file an ISSUES entry rather than
> adapting a client to a drift.

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
| **SIP registrar/proxy** | `127.0.0.1:5060` (host) → Kamailio `:5060` (container) | UDP/TCP SIP, RFC 3261 + digest auth | `SipClient` | ✅ stable |
| **SMPP SMSC** | `127.0.0.1:2775` → OsmoSMSC | SMPP 3.4 (ESME bind/submit) | (see §5: refactored `sms-client` uses its own SMPP `:2076` + Neon today; `2775` is present but not currently consumed) | ✅ stable (present) |
| **SMS intercept REST** | `POST /api/v1/intercept/sms` (`mvno-api:8080`, host `8080`) | HTTP JSON + `X-API-Key` | `sms-client` (optional), Kamailio `route[INTERCEPT_SMS]` | ✅ stable |
| **Call intercept REST** | `POST|GET /api/v1/intercept/call` (`mvno-api:8080`) | HTTP JSON + `X-API-Key` | `SipClient` via Kamailio `route[INTERCEPT]` | ✅ stable |
| **Subscriber balance REST** | `GET /api/v1/intercept/subscriber/{msisdn}` | HTTP JSON + `X-API-Key` | NOC / external consumers | ✅ stable |
| **AI classifier** | `POST /api/v1/classify` on `ai-filter:8000` (host `8008`) | HTTP JSON — 3 event types (Section 3) | `telecom-api` outbound; drop-in target for `AI-Filteration-System` | ✅ mock-authoritative |
| **Post-call analytics REST** | `POST /api/v1/transcriptions` (`mvno-api:8080`) | HTTP JSON (transcript + biometrics + DTMF) | external clients pushing post-call analytics | ✅ stable (inbound only) |

The inline mock (defined in `docker-compose.yml`) is the **authoritative classifier
for the demo**: it returns `allow:false` / `reason:"Spam (E2E deterministic block)"`
whenever the request body contains the marker `E2E-BLOCK`, else `allow:true`
(`reason:"Clean content"`). The marker works for **all three event types** (SMS content,
VOICE_CALL metadata, TRANSCRIPT text alike) because the mock is event-type agnostic.
The sms_matrix's AI-block cell (Goal 7) asserts this path for SMS. The mock also parses
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
  `X-API-Key` header (see `kamailio.cfg` `route[INTERCEPT]`, `http_client_query`). Query params are
  `caller`, `callee`, `call_id`, `imei` (all optional; blank `caller` → `400`). `POST
  /api/v1/intercept/call` carries the same fields as a JSON body (`CallInterceptRequest`:
  `caller`, `callee`, `call_id`, `imei`). Caller/callee are E.164 MSISDNs; the gateway response is
  `{ "allow": boolean, "reason": "string" }` — `allow:false` → Kamailio rejects the call with
  `403 Call Intercepted / Blocked`.

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

**Inbound post-call analytics (external clients → MVNO, `POST /api/v1/transcriptions`)** —
schema from `TranscriptionController` (`Telecom-api`):
```json
{
  "callId": "call-<epoch>%<host>-<hash>",
  "audioFile": "call-<epoch>%<host>-<hash>.wav",
  "transcript": "Hello, this is your bank...",
  "biometrics": { "silenceRatio": 0.31, "spectralFlatness": 0.08, "durationSeconds": 18.4 },
  "dtmfEvents": [ { "digit": 1, "timestamp": 1721590001000 } ]
}
```
Response: `200 {"status":"received"}`. No `X-API-Key` required (not under `/intercept/**`).

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

### SipClient (`com.sipclient.sip.config.SipConfig`) — ⚠ re-verified 2026-08-14 (hardcoded, NOT sip.properties)
> **Correction (verified against `origin/main` and `feature/kamailio-integration`,
> 2026-08-14):** the earlier "✅ loads from `src/main/resources/sip.properties`"
> claim is **FALSE**. `SipConfig.java` is **hardcoded constants** — `LOCAL_IP=127.0.0.1`,
> `LOCAL_PORT=5070`, `SERVER_PORT=5060`, `TRANSPORT=udp`; **no `sip.properties` file exists**
> in the repo. Pointing SipClient at a different MVNO host requires **editing
> `SipConfig.java` and recompiling** — there is no config-file path today.
- **Connecting SipClient to an MVNO host**: edit `SipConfig.java` (the
  `SERVER_HOST`/`SERVER_PORT`/`LOCAL_IP`/`LOCAL_PORT` constants), rebuild with
  Maven, run. MVNO does not edit external repos; if properties loading is
  wanted, file a PR in the SipClient repo (recommended: add a
  `src/main/resources/sip.properties` with `sip.server.host`/`sip.server.port`
  keys and `@Value`-inject them — MVNO will not do this for you).
- **MVNO Kamailio host port is `5060`** (canonical, `5060:5060/udp`). A host-level
  Asterisk formerly held `0.0.0.0:5060`; it is removed, so 5060 is free.
- **SIP INVITE Authentication (407 Digest):** Kamailio challenges unauthenticated `INVITE` with
  `407 Proxy Authentication Required`. Clients MUST handle the `Proxy-Authenticate: Digest`
  challenge and retry with an `Authorization: Digest` header using their subscriber-table
  credentials (`username: MSISDN`, realm `localhost`, password `testpass`). Applies to REGISTER and
  INVITE alike.
- **RTP Media Relay:** RTPEngine ports `10000-20000/udp` (G.711u PCMU codec supported).
- **Codec:** configure the client for **PCMU (G.711u, payload type 0) only** — the relay does not
  transcode; PCMA/opus negotiations fail media.
- **Blocked calls:** zero-balance / EIR-fraud / AI-blocked calls are rejected with
  `SIP/2.0 403 Forbidden` — treat 403 as a terminal call failure (no retry loop).
- **Firewall:** open UDP `10000-20000` (RTP relay range) and UDP `5060` (SIP) between client host
  and MVNO host; the client's own RTP socket must be reachable (see `fix_nated_contact()` in
  `configs/kamailio/kamailio.cfg`).
- **Any RFC-3261 softphone works (mobile/desktop)**: MVNO publishes `5060/udp` and RTP
  `10000-20000/udp` on **all host interfaces** (`*`, verified live), so a phone on the same LAN can
  REGISTER directly with `username=<MSISDN>`, `password=testpass`, realm `localhost`, server
  `<host-ip>:5060`, codec **PCMU only**. See `docs/LIVE_DEMO.md` S15 and
  `docs/partner/SipClient-INTEGRATION.md` (drop-in for the repo's README).

### sms-client (`src/main/resources/application.properties`) — ⚠ re-verified 2026-08-09 against `origin/main @ 1a388af`
> **Current truth (origin/main @ `1a388af`, refactored client)**: ships its **own
> SMPP server on `:2076`** (the teammate classification server, NOT the MVNO
> SMSC), **Neon Postgres** read-only history (`db.url`), **login + phone-number
> ownership**, and **no `sms.blockSpam`/`ai.classify` keys**. Integration
> consequence: the classic MVNO drop-in at `2775` **does not apply today** — this
> client does not talk to `osmo-smsc` unless re-pointed. Plan against this shape.
>
> **Planned org flow (when the Filteration-System decider is wired —
> `docs/filteration-system-handoff.md`)**: `sms-client` re-points to **`:2076`**
> (the decider's SMPP listener); the decider forwards clean SMS to MVNO
> `osmo-smsc:2775`. MVNO stays in-band **transport**; `2775` remains the SMSC
> seam but the client's target becomes `2076`.
>
> **Legacy/classic shape** (pre-refactor `ddb3df8`, rollback/reference only):
- `smpp.host=127.0.0.1`, `smpp.port=2775` — ✅ still matches MVNO's `osmo-smsc` publish
  (`docker-compose.yml` `2775:2775`; `osmo-smsc.cfg` `esme smsclient` route), but this exact
  wiring is **rollback/reference only** — the refactored `origin/main @ 1a388af` client does not
  target `2775` today. When Filteration-System is wired (see handoff
  `docs/filteration-system-handoff.md`), this port becomes **`2076`** (the org filter's SMPP
  listener) — MVNO is bypassed until then.
- `smpp.systemId=smsclient`, `smpp.password=password` → matches the `esme smsclient` route ✅
  (MVNO SMSC System-ID `MVNO_SMSC`; primary ESME `mvno-api-route`/`changeme`).
- `ai.classify.url=http://localhost:5000/classify` — ⚠ **dead endpoint** (nothing serves :5000
  on this host; MVNO's mock is `ai-filter:8000/api/v1/classify`). The client fails **open** to
  `Classification.UNKNOWN` on connect/read errors (`ai.connectTimeoutMs=3000`,
  `ai.readTimeoutMs=5000`), so SMS delivery is unaffected — the classify call is a silent no-op
  in the current standalone demo. Response shape expected: `{ "label": "spam|ham", "score": 0.x }`
  (⚠ **not** the MVNO mock's `{ "allow", "reason" }` — a drop-in URL swap alone does NOT activate
  blocking).
- `sms.blockSpam=false` — ⚠ **blocking is OFF by default**: even a real `spam` verdict would NOT
  stop submission until this is `true` (or `-Dsms.blockSpam=true`). MVNO-side blocking
  (telecom-api → ai-filter → 403) is the standalone-demo enforcement path.
- `server.port=8080` ⚠ overlaps `telecom-api`'s `8080` if co-hosted — run on a different host/port
  (e.g. `-Dserver.port=8081`). All keys are overridable via `-Dkey=value`.
- **REST Interception (optional):** `POST http://telecom-api:8080/api/v1/intercept/sms` with
  `X-API-Key: mvno-demo-key-2026`; response `{ "allow": boolean, "reason": "string" }`.
- **Shared Neon history (schema-preserving)**: MVNO may write rows into the existing
  `subscribers` / `messages` / `blocklist` / `logs` tables via the `NEON_DB_URL` env var —
  **rows only, never DDL** (bodies/transcripts are intentionally NOT stored). Full table
  inventory + example insert: `docs/partner/sms-client-INTEGRATION.md`.

### AI-Filteration-System (`ai-model.py`) — endpoint documented, repo private (not verifiable)
- FastAPI at `:8000/api/filter-sms`, requires `API_KEY` + `MODEL_ID` (routes to agentrouter.org).
- For the MVNO demo the **inline `mvno-ai-filter` mock is authoritative** and now
  implements a **deterministic AI-block rule** (`E2E-BLOCK` marker → `allow:false`),
  added config-only in `docker-compose.yml` and **verified end-to-end** by the Goal 7
  `sms_matrix.sh` AI-block cell (Kamailio 403 + `mvno_sms_blocked_total` increment,
  two consecutive green runs). No external classifier or API key is required.
- **Drop-in criteria** (to replace the mock in the live demo):
  - Must expose `POST /api/v1/classify` on `0.0.0.0:8000` inside the `mvno_net` network.
  - Must accept **all three event types** (Section 3) and return `{ "allow": boolean, "reason": "string" }`.
  - Must classify within the 5s read window (target ≤ 500ms per the SLA contract).
  - Package as container image `mvno-ai-filter:1.0.0`; attach to `mvno_net` in `docker-compose.yml`.
  - Verify with `make test-sms` and `make test-call`.
  - Full-stack regression oracle: `make gate` (`scripts/testing/gate.sh` — 5G preflight probe + sms_matrix, 8 cells incl. the AI-block cell asserting the live Kamailio block line and `mvno_sms_blocked_total`).
- **Deterministic fallback layer (REQUIRED for the demo and the gates):**  - The e2e Goal-7 AI-block cell asserts the `E2E-BLOCK` marker → `allow:false` and the demo's
    post-call scam-block story asserts phishing-keyword blocking on `TRANSCRIPT` events
    (word-boundary, lowercase: `won`, `prize`, `claim`, `free`, `urgent`, `account`, `blocked`,
    `confirm` — tuned to Vosk small-model ASR output, e.g. the demo phrase
    "Your bank account has been blocked, please confirm your details now" →
    Vosk hears `your bank account has been blocked please confirm your detail now`,
    which keeps the `account`/`blocked`/`confirm` anchors; the older phrase
    "You have won a prize, call us now" → Vosk heard `you have won an prize called us out`).
  - The replacement MUST keep an equivalent deterministic rule layer (marker + keyword list) OR
    prove the model blocks those exact inputs — otherwise `sms_matrix.sh` and `live_demo.sh`
    check 9 break and the demo's blocked-call story is unverifiable.
- **TRANSCRIPT events are post-call analytics only**: verdicts never retro-block an in-flight call;
    they increment `mvno_vosk_blocked_total` and appear in the mvno-api log.

### Filteration-System (SMPP in-band filter + voice decider — the org's decider) — verified via source audit 2026-08-14
> The intended live decider per the org's separation of concerns. It is **SMPP-based, not REST**
> for SMS, and now also exposes a **voice adjudication REST endpoint** (see below). It sits
> **in-band between the ESME and the MSC**, so SMS traffic must be re-routed through it
> (see `docs/filteration-system-handoff.md` for the full teammate-facing contract).
- **Topology (from source):** `ESME → SMPP :2076 → Filteration-System [decides] → SMPP → MSC :2775 → MT`.
  - `SmppServerManager`: SMPP server listener on **`2076`** (binds as `SpamFilter`), attaches
    `SpamFilterMessageReceiver` per session.
  - `SpamFilterMessageReceiver`: on each `SUBMIT_SM`/`DELIVER_SM` calls
    `filterService.isSpam(sender, receiver, body)`; spam → reject (`STAT_ESME_RSUBMITFAIL`,
    never forwarded); clean → `OsmoMscClient` forwards to the MSC.
  - `SpamFilterService.isSpam`: **whitelist → blocklist → AI LLM** (HTTP to agentrouter.org);
    an AI "spam" hit writes a new `Blocklist` row (self-learning).
- **Voice adjudication hook (NEW — verified 2026-08-14):** `VoiceFilterController` exposes
  `POST /api/v1/voice/filter` `{callerId, receiverId, transcript}` →
  `{malicious, DROP_CALL | ALLOW_CALL}`. This **matches MVNO's `FILTERATION_VOICE_URL`
  wiring** in `docker-compose.yml` (`telecom-api` posts post-call transcripts there).
  Earlier "no call (non-SMPP) adjudication hook today" is **stale** — the hook exists now.
- **Real repo vs. compose mock:** MVNO's compose `filteration-system` service is a
  **deterministic Python mock** (`python:3.11-alpine` inline `http.server` on `8000`)
  — the real Spring Boot repo runs `server.port=8081` with SMPP on `2076`. The real
  repo is **not deployed in the MVNO stack**; only the mock is. To wire the real repo:
  re-point `FILTERATION_VOICE_URL` to the real service (or remap its port to the compose
  expectation).
- **Wiring notes for MVNO co-deployment:**
  - `OsmoMscClient` targets `localhost:2775` — i.e. Filteration-System must run in a network
    where `localhost:2775` reaches MVNO's `osmo-smsc` (same container network / same host).
  - **Port collision**: `2775` is MVNO's published SMPP port — Filteration-System must NOT also
    publish `2775` on the same host (use container networking instead of host publish).
  - `sms-client` re-points to `:2076` to enter the filter (deferred per org decision — MVNO demo
    stays standalone until the wiring phase).
- **Call path gap**: the voice hook exists, but the end-to-end SipClient→MVNO→decider call flow
  is not wired in the standalone demo — call verdicts stay with MVNO's `telecom-api` →
  `ai-filter` proxy (fail-open SLA) until the real Filteration-System is co-deployed.

### admin-client (Neon Postgres UI — NOT an MVNO REST client)
> **New section (verified 2026-08-14).** The admin-client repo runs `server.port=8082`
> and is a **DB UI over the shared Neon Postgres schema** (`db.url` env; tables
> `messages`, `calls`, `subscribers`, `logs`, `blocklist`, `whitelisted_senders`),
> with role-gated login (`ROLE_ADMIN` / `ROLE_ESCALATION`).
- **Integration surface:** it does **not** talk to MVNO REST at all — it reads/writes
  the **same Neon Postgres** MVNO writes to via `NEON_DB_URL` (rows only, schema shared).
  Schema coordination (not DDL) is the only seam.
- **Contract implication:** nothing to wire in MVNO compose; verify the shared table
  names/columns match the Neon schema MVNO's `NEON_DB_URL` targets.

---

## 6. (superceded) `MVNO_PUBLISH_5060` / `docker-compose.5060.yml`

- Kamailio is now published directly on the **canonical host port `5060`** (`5060:5060/udp`),
  so the earlier opt-in `5060` extra-publish override (`docker-compose.5060.yml`) is **removed**.
  There is no longer any need to publish 5060 additionally — it is the default.
- On a host where another SIP daemon (e.g. a local Asterisk) holds `0.0.0.0:5060`, that listener
  must be stopped for Kamailio to bind. `scripts/preflight.sh` checks `ss -lun | grep :5060`
  and warns loudly if 5060 is occupied.

---

## 7. MVNO-side stability guarantee

MVNO keeps these seams stable across changes so external clients keep working without edits:
- `POST /api/v1/intercept/sms`, `POST|GET /api/v1/intercept/call` request/response schemas.
- `POST /api/v1/classify` with the three event types (SMS, VOICE_CALL, TRANSCRIPT) + `{allow, reason}`.
- SMPP `2775` + the `esme smsclient`/`esme mvno-api-route` routes.
- SIP `5060` host port + digest `subscriber` table credentials (`testpass`).
- `POST /api/v1/transcriptions` inbound schema (transcript + biometrics + DTMF).

Any breaking change to these is a **coordinated, versioned contract change** communicated to the consuming repositories.

---

## 8. Partner handoff package (files to share with each repository)

### Filteration-System (org decider — SMPP in-band filter)
| Artifact | Why |
|---|---|
| `docs/filteration-system-handoff.md` | **the handoff contract**: SMPP `:2076` bind, `isSpam(sender, receiver, body)` signature, RSUBMITFAIL semantics, whitelist/blocklist/AI-LLM order, self-learning blocklist, `OsmoMscClient` → `localhost:2775` wiring + port-collision note, sms-client `:2775→:2076` re-point, call-adjudication hook request |
| `docs/INTEGRATION_CONTRACT.md` Section 5 (Filteration-System) | verified topology summary |
| `configs/osmocom/osmo-smsc.cfg` | the `esme smsclient`/`esme mvno-api-route` routes the filter's MSC client must authenticate to |

**Prove your integration with**: re-point `sms-client` `smpp.port` to `2076`, run
`./scripts/testing/sms_matrix.sh` (all 5 cells must stay green) and
`./scripts/testing/live_demo.sh` check 10/10b (SUBMIT_SM path).

### AI-Filteration-System (classifier provider)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` (this file) | Section 3 payload schemas (3 event types), Section 4 SLA/fail-open |
| `docker-compose.yml` service `ai-filter` (lines ~543) | reference mock implementation to replace (incl. deterministic keyword/E2E-BLOCK fallback layer) |
| `telecom-api/.../filter/AiFilterService.java` | exact outbound call semantics (`AI_FILTER_URL`, timeouts, circuit breaker) |
| `telecom-api/src/test/java/.../AiFilterSlaTimeoutTest.java` | SLA behavior the model must satisfy |
| `scripts/testing/sms_matrix.sh` Goal 7 cell | the AI-block assertion the model must keep green |

**Prove your integration with**: `make test-sms` + `make test-call`; `./scripts/testing/sms_matrix.sh` (Goal 7 AI-block cell must stay green — requires your container to keep the deterministic `E2E-BLOCK`/keyword rules); `./scripts/testing/live_demo.sh` check 9b (scam speech → `allow:false` + `mvno_vosk_blocked_total` increment).

### SipClient (voice user agent)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` Section 1, Section 5 (SipClient), Section 6 | ports, digest auth, PCMU-only codec, 403 semantics, RTP range, `MVNO_PUBLISH_5060` |
| `docs/ENVIRONMENT_MATRIX.md` Section 3 | why host `5060` is blocked (Asterisk) |
| `configs/kamailio/kamailio.cfg` `route[INTERCEPT]` | call-intercept callout behavior |
| `docs/TESTING_REFERENCE.md` voice flows | end-to-end call + RTP + recording verification steps (Flow E, T6/T7/T8); raw-shell baresip variant in `docs/LIVE_DEMO.md` S3 |
| `scripts/testing/sip_traffic_sim.py` | reference UA — your client must reproduce its REGISTER/407→digest→INVITE→RTP behavior |

**Prove your integration with**: `./scripts/testing/live_demo.sh` check 5 (replace the sim caller with your client: REGISTER 200 OK, call answered, `rtpengine_bytes_total` moves) and check 6 (your client must surface the 403 Forbidden from a zero-balance call). Also Flow E T6/T7 for the full media dialog.

### sms-client (SMPP ESME)
| Artifact | Why |
|---|---|
| `docs/INTEGRATION_CONTRACT.md` Section 1, Section 5 (sms-client) | SMPP `2775` today (→ `2076` when Filteration-System is wired), `MVNO_SMSC`, ESME accounts, dead `ai.classify.url` + `sms.blockSpam=false` caveats, intercept REST |
| `configs/osmocom/osmo-smsc.cfg` | the `esme smsclient` / `esme mvno-api-route` routes |
| `docs/TESTING_REFERENCE.md` SMS flows | 2G/5G + IP-SM-GW delivery verification; raw-shell variants in `docs/LIVE_DEMO.md` S6–S8 |
| `scripts/testing/sms_matrix.sh` | 5-cell SMS matrix (2G→2G, 2G→5G, 5G→2G, 5G→5G, AI-block) |
| `scripts/testing/send_smpp_sms.py` | reference ESME — your client must reproduce BIND_TRANSCEIVER + SUBMIT_SM against `127.0.0.1:2775` |

**Prove your integration with**: `./scripts/testing/live_demo.sh` check 10 (binary BIND_TRANSCEIVER) + check 10b (SUBMIT_SM ESME_ROK) — replace the harness with your client; `./scripts/testing/sms_matrix.sh` (all 5 cells, incl. the AI-block 403 path).
