# Integration Specification: MVNO Core <-> AI-SpamFilter-PMN (`INTEGRATION_AI_SPAM_FILTER.md`)

This document defines the interface contracts, SLA constraints, networking parameters, and integration checklist required to connect the **MVNO Telecom Infrastructure** (`telecom-api`, `kamailio`, `osmo-smsc`) with the **AI Spam Filter Team (`AI-SpamFilter-PMN`)**.

---

## 1. Overview & Architecture Boundary

```
┌─────────────────────────────────────────────────────────┐
│              MVNO Telecom Infrastructure                │
│                                                         │
│  [Kamailio / OsmoMSC] ──▶ [telecom-api Gateway]         │
│                                │ (HTTP REST / Sub-2s)   │
└────────────────────────────────┼────────────────────────┘
                                 ▼
┌─────────────────────────────────────────────────────────┐
│            AI Spam Filter Team (AI-SpamFilter-PMN)      │
│                                                         │
│  [ai-filter:8000] ──▶ [PyTorch / FastAPI / ONNX Model] │
└─────────────────────────────────────────────────────────┘
```

The Telecom Gateway (`telecom-api`) acts as the intermediary between raw telecom protocols (SIP, SMPP) and the AI classification engine (`ai-filter`).

---

## 2. API Contract & Payload Schema (`POST /api/v1/classify`)

### Request Payload (Sent by `telecom-api` to `ai-filter:8000`)
```json
{
  "event_type": "SMS",
  "sender_msisdn": "15551234567",
  "recipient_msisdn": "15559876543",
  "content_text": "Urgent: Claim your free prize now at http://spam.link",
  "timestamp_epoch_ms": 1721590000000,
  "call_id": "sip-call-id-12345@10.0.0.1"
}
```

* **`event_type`**: `"SMS"` or `"VOICE_TRANSCRIPT"`.
* **`sender_msisdn`**: Originating E.164 phone number.
* **`recipient_msisdn`**: Destination E.164 phone number.
* **`content_text`**: Raw SMS message text OR transcribed voice call text from Vosk STT.
* **`timestamp_epoch_ms`**: Event timestamp in epoch milliseconds.
* **`call_id`**: Optional SIP call ID or SMPP sequence ID for correlation.

---

### Response Payload (Expected by `telecom-api` from `ai-filter:8000`)
```json
{
  "is_spam": true,
  "confidence_score": 0.98,
  "risk_category": "PHISHING",
  "action": "BLOCK",
  "reason": "High-probability phishing link detected"
}
```

* **`is_spam`**: `true` if identified as spam/fraud, `false` otherwise.
* **`confidence_score`**: Float between `0.0` and `1.0`.
* **`risk_category`**: `"PHISHING"`, `"SPAM"`, `"SMISHING"`, `"VOIP_FRAUD"`, or `"HAM"`.
* **`action`**: `"BLOCK"`, `"ALLOW"`, or `"FLAG"`.
* **`reason`**: Human-readable explanation for NOC audit logging.

---

## 3. Critical SLA Constraints & Fail-Open Behavior

### 1. Sub-2-Second Latency Limit
Telecom signaling timers (SIP `T303`/`T310` and SMPP submit timeouts) require call/SMS routing decisions within 3 seconds.
- **`telecom-api` enforces a 2.0-second HTTP client timeout** (`ai-filter.timeout-seconds: 2`).
- **Teammates must guarantee model inference latency $\le 200\text{ ms}$** per classification.

### 2. Carrier SLA Fallback (Fail-Open)
If `ai-filter:8000` is offline, times out ($> 2.0\text{s}$), or returns an HTTP 5xx error, `telecom-api` automatically executes **Carrier SLA Fallback**:
```json
{
  "allow": true,
  "reason": "AI filter unreachable — SLA allow"
}
```
*SMS/Calls will be allowed through to prevent carrier service outages.*

---

## 4. Teammate Communication & Integration Checklist

Share the following checklist with your teammates on the `AI-SpamFilter-PMN` project:

### Network & Container Setup
- [ ] **Container Service Name**: Name container/service `ai-filter` in Docker/Podman compose.
- [ ] **Bridge Network**: Attach `ai-filter` container to `mvno_net` bridge network.
- [ ] **IP Binding**: Bind FastAPI/Uvicorn server to `0.0.0.0:8000` inside container (NOT `127.0.0.1`).
- [ ] **Exposed Port**: Expose port `8000` internally on `mvno_net`.

### Model Performance & Throughput
- [ ] **Inference Speed**: Optimize PyTorch/BERT/RoBERTa model using ONNX Runtime, TensorRT, or quantization to achieve $\le 200\text{ ms}$ latency per request.
- [ ] **Concurrency**: Run Uvicorn/FastAPI with `--workers 4` or async event loop (`async def classify`) to handle concurrent requests without blocking.
- [ ] **Batching**: Enable dynamic batching if processing bulk SMS streams.

### Text & Noise Handling
- [ ] **Speech-to-Text Noise**: Model must handle raw ASR transcriptions (which may lack punctuation or contain minor phonetic misspellings).
- [ ] **Special Characters**: Model must handle URL links, emojis, and non-ASCII character sets.

### Health Check Endpoint
- [ ] Implement `GET /health` or `GET /api/v1/health` returning `{"status": "UP"}` for container health monitoring.

---

## 5. Environment Variables Summary

In `docker-compose.yml`:
```yaml
  telecom-api:
    environment:
      AI_FILTER_URL: http://ai-filter:8000/api/v1/classify
      AI_FILTER_TIMEOUT_SECONDS: 2
```
