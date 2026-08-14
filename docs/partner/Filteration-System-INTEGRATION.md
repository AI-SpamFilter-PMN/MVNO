# Filteration-System ↔ MVNO — Integration Guide (drop-in for this repo's README)

> Intended for the **`AI-SpamFilter-PMN/Filteration-System`** repo maintainer
> (Spring Boot, `com.telecom.spamfilter`). MVNO
> (`AI-SpamFilter-PMN/MVNO`) is the transport + interception core; this repo is
> the org's **decider**. Full contract: MVNO **`docs/INTEGRATION_CONTRACT.md`**,
> with the detailed in-band handoff in MVNO `docs/filteration-system-handoff.md`
> (⚠ the source audit there is dated 2026-08-03 — confirm class names/wiring
> against this repo's current `main`).

## Role in the architecture

```
SMS : sms-client (ESME) ──SMPP 2076──▶ Filteration-System [DECIDES] ──SMPP 2775──▶ osmo-smsc ──▶ MT
CALL: SipClient ─▶ MVNO (Kamailio/telecom-api: capture + Vosk ASR) ──sync HTTP──▶ Filteration-System [DECIDES]
                                                              (call hook to be added — §4 of the handoff)
```
MVNO = transport + interception + transcription only; Filteration-System authors
every verdict (blocklist / sender policy / AI LLM).

## SMS contract (in-band, SMPP)

| Item | Spec |
|---|---|
| SMPP listener | Bind `:2076`, system-id `SpamFilter`, accept `BIND_TRANSCEIVER` (`smsclient`/`password`) |
| Decision hook | `isSpam(sender, receiver, body) → boolean` |
| Decision order | whitelist → blocklist → AI LLM (agentrouter) |
| Block semantics | spam → `STAT_ESME_RSUBMITFAIL` (never forwarded to MT) |
| Forward path | `OsmoMscClient` → `localhost:2775` (MVNO `osmo-smsc`, ESME `mvno-api-route`/`changeme` or `smsclient`/`password`) |
| Fail-open | AI LLM error/timeout → **allow** (carrier SLA), never a hard drop |

> Port-collision: do **not** publish `2775` on a host where MVNO already
> publishes `2775:2775` — use container networking.

## Call adjudication contract (to add — recommended shape)

```http
POST /api/v1/classify
Content-Type: application/json

{ "event_type": "VOICE_CALL", "caller_msisdn": "15551234567",
  "callee_msisdn": "15557654321", "call_id": "call-123",
  "timestamp_epoch_ms": 1721590000000 }

→ 200 {"allow": true|false, "reason": "string"}
```
Also accept `SMS` (sender/recipient/content_text) and `TRANSCRIPT` (call_id +
transcript) events. MVNO's `telecom-api` proxies this contract with a **fail-open
SLA** (1 s connect / 5 s read / circuit breaker → allow). `sms-client`'s
`{label, score}` shape is **not** canonical — coordinate on `{allow, reason}`.

> **Deterministic fallback is REQUIRED for MVNO demo gates**: keep an
> equivalent rule layer (`E2E-BLOCK` marker → `allow:false`; transcript keyword
> anchors `won|prize|claim|free|urgent|account|blocked|confirm`) or prove the
> model blocks those exact inputs — otherwise MVNO `sms_matrix.sh` Goal 7 and
> `live_demo.sh` check 9b break.

## Prove your integration

1. `smpp.port=2076` in sms-client → MVNO `sms_matrix.sh` **5/5 cells green**.
2. `live_demo.sh` check 9b: scam speech → `allow:false` +
   `mvno_vosk_blocked_total` increments; check 9d: clean → `allow:true`.
3. Kill the filter mid-run → calls/SMS **still pass** (fail-open,
   `mvno_ai_failopen_total` moves).