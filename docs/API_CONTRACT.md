# API Contract & Integration Specification: MVNO Core <-> AI-SpamFilter-PMN (`docs/API_CONTRACT.md`)

This document defines the interface contracts, SLA constraints, networking parameters, and integration checklist required to connect the **MVNO Telecom Infrastructure** (`telecom-api`, `kamailio`, `osmo-smsc`) with the **AI Spam Filter Team (`AI-SpamFilter-PMN`)**.

---

## 0. Gateway Authentication (X-API-Key — Zero-Trust Section 1.2)

All `telecom-api` interception endpoints (`POST /api/v1/intercept/sms`, `GET /api/v1/intercept/call` — Kamailio callout, `POST /api/v1/intercept/call`, `GET /api/v1/intercept/subscriber/{msisdn}`) require the header:

```
X-API-Key: mvno-demo-key-2026
```

- Missing or mismatched key → `HTTP 401 Unauthorized`.
- Demo key default from `intercept.api-key` property (env override: `X_API_KEY`).
- Not required for `/actuator/*` health/metrics endpoints (scrape-safe).
- **Scope**: only `/api/v1/intercept/**` is key-protected. `POST /api/v1/classify` (outbound to `ai-filter`) and `/actuator/*` are unaffected; SIP (407 digest) and SMPP (ESME credentials) authenticate at their own protocol layers.
- **Kamailio callout** (voice path): `GET /api/v1/intercept/call?caller=<$fU>&callee=<$rU>` with the `X-API-Key` header (see `kamailio.cfg` `route[INTERCEPT]`, `http_client_query`). Caller/callee are E.164 MSISDNs; the gateway response is `{ "allow": boolean, "reason": "string" }` — `allow:false` → Kamailio rejects the call with `403 Call Intercepted / Blocked`.

---

## 1. Overview & Architecture Boundary

```
┌─────────────────────────────────────────────────────────┐
│              MVNO Telecom Infrastructure                │
│                                                         │
│  [Kamailio / OsmoSMSC] ──▶ [telecom-api Gateway]        │
│                                │ (HTTP REST / Sub-5s)   │
└────────────────────────────────┼────────────────────────┘
                                 ▼
┌─────────────────────────────────────────────────────────┐
│            AI Spam Filter Team (AI-SpamFilter-PMN)      │
│                                                         │
│  [ai-filter:8000] ──▶ [AI Model REST Service]           │
└─────────────────────────────────────────────────────────┘
```

The Telecom Gateway (`telecom-api`) acts as the intermediary between raw telecom protocols (SIP, SMPP) and the AI classification engine (`ai-filter`).

---

## 2. API Contract & Payload Schema (`POST /api/v1/classify`)

### Request Payloads (Sent by `telecom-api` to `ai-filter:8000`)

Payload shape is **event-typed** — SMS and VOICE_CALL carry different fields (verified against `AiFilterService.java`).

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

* **`event_type`**: `"SMS"` or `"VOICE_CALL"`.
* **`sender_msisdn`** / **`recipient_msisdn`** (SMS only): Originating / destination E.164 phone number.
* **`content_text`** (SMS only): Raw SMS message text. Voice transcriptions are NOT included in the classify payload.
* **`caller_msisdn`** / **`callee_msisdn`** (VOICE_CALL only): Originating / destination E.164 phone number.
* **`call_id`** (VOICE_CALL only): SIP call ID for correlation; never sent for SMS.
* **`timestamp_epoch_ms`**: Event timestamp in epoch milliseconds.

---

### Response Payload (Expected by `telecom-api` from `ai-filter:8000`)
```json
{
  "allow": false,
  "reason": "High-probability phishing link detected"
}
```

* **`allow`**: `true` if call/SMS setup is allowed; `false` to block message/call delivery.
* **`reason`**: Human-readable classification explanation for NOC audit logging.

---

## 3. Cross-Repository Integration Specifications

### 1. AI Classification Engine (`ai-filter` drop-in criteria)
- Must replace mock `ai-filter` container in `docker-compose.yml` with classification engine listening on port `8000`.
- Endpoint: `POST /api/v1/classify` taking request schema above and returning `{ "allow": boolean, "reason": "string" }`.

### 2. SMS Client (`sms-client`)
- **SMPP Listener**: Connects to `OsmoSMSC` on TCP port `2775`.
- **SMSC System-ID**: `MVNO_SMSC`
- **Primary ESME Account**: `mvno-api-route` / password `changeme`
- **Secondary Client ESME Account**: `smsclient` / password `password`
- **REST Interception**: Calls `POST /api/v1/intercept/sms` on `telecom-api:8080`. Expects response `{ "allow": boolean, "reason": "string" }`.

### 3. Voice Client (`SipClient`)
- **SIP Registrar & Proxy**: Target host port `5066/udp` (`localhost:5066` on host, maps to `kamailio:5060` inside container network).
- **SIP INVITE Authentication (407 Digest)**: Kamailio challenges unauthenticated `INVITE` with `407 Proxy Authentication Required` (zero-trust Section 1.1). Clients MUST handle the `Proxy-Authenticate: Digest` challenge and retry with an `Authorization: Digest` header using their subscriber-table credentials (`username: MSISDN`, realm `localhost`). Applies to REGISTER and INVITE alike.
- **RTP Media Relay**: RTPEngine ports `30000-30100/udp` (G.711u PCMU codec supported).

---

## 4. SLA Constraints & Fail-Open Behavior

### 1. Split-Timeout Windows
- **`AI_FILTER_CONNECT_TIMEOUT_SECONDS`**: 1s connect timeout.
- **`AI_FILTER_READ_TIMEOUT_SECONDS`**: 5s read timeout to accommodate CPU model inference latency.

### 2. Carrier SLA Fallback (Fail-Open)
If `ai-filter:8000` is offline, times out ($> 5.0\text{s}$), or returns an HTTP 5xx error, `telecom-api` automatically executes **Carrier SLA Fallback**:
```json
{
  "allow": true,
  "reason": "AI filter unreachable — SLA allow"
}
```
*SMS/Calls will be allowed through to prevent carrier service outages.*

**Observability**: every fail-open increments `mvno_ai_failopen_total{reason}` (Micrometer, exported at `/actuator/prometheus`, scraped into VictoriaMetrics; Grafana alert `MVNO AI Fail-Open SLA Rate`). `reason` ∈ `unreachable` | `empty_response` | `internal` | `circuit_open` — the SLA contract is instrumented end-to-end.

---

## 5. Environment Variables Summary

In `docker-compose.yml` / `application.yml`:
```yaml
AI_FILTER_URL: http://ai-filter:8000/api/v1/classify
AI_FILTER_CONNECT_TIMEOUT_SECONDS: 1
AI_FILTER_READ_TIMEOUT_SECONDS: 5
```
