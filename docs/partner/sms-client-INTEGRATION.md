# sms-client ↔ MVNO — Integration Guide (drop-in for this repo's README)

> Intended for the **`AI-SpamFilter-PMN/sms-client`** repo maintainer. MVNO
> (`AI-SpamFilter-PMN/MVNO`) is the central core-net repo. This is the current
> truth as of **2026-08-09**, cross-checked against MVNO `main` and this repo's
> `origin/main` (`1a388af`). Canonical contract: **`docs/INTEGRATION_CONTRACT.md`** in MVNO.

## Status — read this first (it changes your wiring)

- **`origin/main @ 1a388af` (refactored client)** talks to **its own SMPP server
  on `:2076`** (the classification server) + **Neon Postgres** (`db.url`,
  read-only history) + login/phone-number ownership. It does **not** currently
  connect to the MVNO SMSC on `:2775`.
- Therefore the old "drop-in at `2775`" path does **not** apply until re-pointed.

## Connection facts (for when you wire back in)

| Item | Value |
|---|---|
| MVNO SMSC (SMPP 3.4, BIND_TRANSCEIVER) | `osmo-smsc:2775` (container) / `127.0.0.1:2775` (host) |
| SMSC System-ID | `MVNO_SMSC` |
| Primary ESME creds | `mvno-api-route` / `changeme` |
| Secondary ESME creds | `smsclient` / `password` |
| Planned org flow | `sms-client → SMPP :2776 (Filteration-System decider) → :2775 (MVNO SMSC)` |

> Do **not** publish `2775` on a shared host — MVNO already publishes `2775:2775`.
> Use container networking (`mvno_net` bridge / same compose network) instead.

## REST interception (zero-trust)

```http
POST http://<mvno-host>:8080/api/v1/intercept/sms
Content-Type: application/json
X-API-Key: mvno-demo-key-2026

{ "sender": "15551234567", "recipient": "15557654321", "content": "Hello" }
```
Response: `{ "allow": boolean, "reason": string }` · missing/mismatched key → `401`.

> ⚠ The refactored client's `AiClassifierClient` expects `{ label, score }`; MVNO's
> classify contract (for the AI filter) returns `{ allow, reason }`. A bare URL swap
> does **not** activate blocking — pick one canonical shape (recommended: `{allow, reason}`).

## Prove your integration

- MVNO reference clients: `scripts/testing/send_smpp_sms.py` (BIND_TRANSCEIVER +
  SUBMIT_SM against `127.0.0.1:2775`) and `scripts/testing/send_rest_sms.sh`.
- Acceptance: `scripts/testing/sms_matrix.sh` — all 5 cells green
  (2G→2G, 2G→5G, 5G→2G, 5G→5G, AI-block 403) — with **your** client in the loop.
- When the Filteration-System decider is wired: re-point `smpp.port` `2775 → 2776`
  and keep the same cell assertions green.