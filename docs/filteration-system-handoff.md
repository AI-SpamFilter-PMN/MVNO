# Filteration-System — Integration Handoff Contract (for the repo owner)

> **Who this is for**: the owner/maintainer of `AI-SpamFilter-PMN/Filteration-System`
> (Spring Boot, `com.telecom.spamfilter`). The MVNO team does **not** edit that repo;
> this document is the contract its maintainers implement so the org decider can be
> wired into the live flows. MVNO stays a standalone demo until then.
>
> **Status**: ⚠ **RE-VERIFY UPDATED 2026-08-14** — the source audit was refreshed
> 2026-08-14 against the live repo: **SMPP bind confirmed `:2076`** (not 2776),
> **voice hook `VoiceFilterController` EXISTS** (`POST /api/v1/voice/filter`),
> real repo runs `server.port=8081`. Still to confirm when wiring: the
> `OsmoMscClient` → `:2775` credentials and the AI-LLM error path (fail-open).

---

## 1. Role in the architecture (agreed)

```
SMS : sms-client (ESME) ──SMPP 2076──▶ Filteration-System [DECIDES] ──SMPP 2775──▶ osmo-smsc ──▶ MT
CALL: SipClient ──▶ MVNO (Kamailio/telecom-api: capture + Vosk ASR) ──sync HTTP──▶ Filteration-System [DECIDES]
                                                                                      (voice hook EXISTS — §3)
```

- **Filteration-System = the decider** (blocklist / sender policy / AI LLM scoring).
- **MVNO = transport + interception + transcription only** (never authors a verdict
  in the wired topology; the inline demo mock is a standalone-demo placeholder).
- **AI-Filteration-System** (Python, archived) is the reference content scorer shape
  (`POST /api/filter-sms` → `{is_spam, classification: SPAM|HAM}`) — reference only,
  stays archived per repo owner.

## 2. SMS contract (exists in skeleton — complete these points)

| Item | Spec | Status in repo |
|---|---|---|
| SMPP listener | Bind **`:2076`**, system-id `SpamFilter`; accept `BIND_TRANSCEIVER` from `sms-client` (`smsclient`/`password`) | `SmppServerManager` ✅ exists |
| Decision hook | `isSpam(sender, receiver, body)` → `boolean` | `SpamFilterMessageReceiver` ✅ exists |
| Decision order | whitelist → blocklist → AI LLM (agentrouter) | `SpamFilterService` ✅ exists |
| Self-learning | AI "spam" hit writes a `Blocklist` row | ✅ exists |
| Block semantics | spam → reject with `STAT_ESME_RSUBMITFAIL` (never forwarded to MT) | ⚠ verify error path |
| Forward path | `OsmoMscClient` → **`localhost:2775`** (MVNO `osmo-smsc`, ESME `mvno-api-route`/`changeme` or `smsclient`/`password`) | ✅ exists — verify credentials |
| **Port collision** | Do NOT publish `2775` on the host — MVNO already publishes `2775:2775`. Use container networking (`mvno_net` bridge) instead | ⚠ ops note |
| Fail-open | If the AI LLM call errors/timeouts, decision must be **allow** (carrier SLA), never a hard drop of legitimate traffic | ⚠ verify |

**sms-client wiring (when the owner confirms readiness):** `smpp.port=2775` → `2076`.
Optionally enable client-side enforcement with `sms.blockSpam=true`.

## 3. Call contract (voice hook EXISTS — verified 2026-08-14)

> **Update 2026-08-14:** the real Filteration-System repo now has a **voice
> adjudication hook** — `VoiceFilterController` exposes
> `POST /api/v1/voice/filter` `{callerId, receiverId, transcript}` →
> `{malicious, DROP_CALL | ALLOW_CALL}`, matching MVNO's `FILTERATION_VOICE_URL`
> wiring in `docker-compose.yml`. The earlier "hook to be added" status is stale.

MVNO's call path needs a synchronous adjudication point. `telecom-api`'s
`AiFilterService` already proxies to `POST /api/v1/classify` with **three event
types** and a fail-open SLA (1s connect / 5s read / circuit breaker → allow).
Recommended: expose the same contract so MVNO can re-point `AI_FILTER_URL`:

```http
POST /api/v1/classify
Content-Type: application/json

{ "event_type": "VOICE_CALL",
  "caller_msisdn": "15551234567",
  "callee_msisdn": "15557654321",
  "call_id": "call-123",
  "timestamp_epoch_ms": 1721590000000 }

→ 200 {"allow": true|false, "reason": "string"}
```

Also accept `SMS` (sender/recipient/content_text) and `TRANSCRIPT` (call_id +
transcript) events; post-call transcript verdicts are telemetry (increment
`mvno_vosk_blocked_total`), never retro-blocking.

> **Real-repo port note (verified 2026-08-14):** the real Spring Boot repo runs
> `server.port=8081` (SMPP on `2076`). MVNO's compose `filteration-system`
> service is a **Python mock** on `8000` — the real repo is not deployed in the
> stack. Wiring the real repo requires re-pointing `FILTERATION_VOICE_URL` to
> the real service (or remapping its port to the compose expectation).

**Shape mismatch warning**: `sms-client`'s `AiClassifierClient` expects
`{"label": "spam|ham", "score": 0.x}`; MVNO expects `{"allow": bool, "reason": "str"}`.
Pick **one** canonical shape (recommended: `{allow, reason}` for both, and adapt
sms-client) or document a mapping layer — a bare URL swap does not activate blocking.

## 4. Deterministic fallback layer (REQUIRED for the demo gates)

The e2e gate (`sms_matrix.sh` Goal 7) and live_demo check 9b assert deterministic
blocks. The replacement MUST keep an equivalent deterministic rule layer or prove the
model blocks these exact inputs, otherwise the gates break:

- `E2E-BLOCK` marker in any payload → `allow:false` (`reason:"Spam (E2E deterministic block)"`).
- TRANSCRIPT keyword anchors (word-boundary, lowercase): `won`, `prize`, `claim`,
  `free`, `urgent`, `account`, `blocked`, `confirm` (tuned to Vosk small-model ASR).

## 5. Acceptance criteria (definition of done for the wiring)

1. `smpp.port=2076` in sms-client; `sms_matrix.sh` **5/5 cells green** (2G→2G, 2G→5G,
   5G→2G, 5G→5G, AI-block 403).
2. `live_demo.sh` check 9b: scam speech → `allow:false` + `mvno_vosk_blocked_total`
   increments; check 9d: clean call → `allow:true`.
3. Kill the filter mid-run → calls/SMS **still pass** (fail-open, `mvno_ai_failopen_total` moves).
4. `make test-sms` + `make test-call` green with the org service in the loop.

## 6. Artifacts MVNO provides

- `docs/INTEGRATION_CONTRACT.md` — full classify payload schemas + SLA section.
- `docker-compose.yml` service `ai-filter` (lines ~543) — the mock to replace (keeps
  deterministic fallback layer).
- `telecom-api/.../filter/AiFilterService.java` — exact outbound semantics.
- `scripts/testing/sms_matrix.sh` — the assertions the decider must keep green.
