# MVNO Core — Integration Contract (Teammate Repos)

This document defines the **public interfaces the MVNO core exposes** to the three
teammate repos (`AI-Filteration-System`, `SipClient`, `sms-client`), so teammates can plug
their clients in **without modifying their own repos**. The MVNO is the central repo;
teammate repos are treated as **read-only external consumers**.

> Principle: MVNO exposes stable interfaces; teammates align their clients to them.
> MVNO never edits teammate repos. Gaps are surfaced as *recommendations*, never as edits.

---

## 1. Interfaces MVNO exposes

| Interface | Endpoint / Port | Protocol | Consumed by | Status |
|---|---|---|---|---|
| **SIP registrar/proxy** | `127.0.0.1:5066` (host) → Kamailio `:5060` (container) | UDP/TCP SIP, RFC 3261 + digest auth | `SipClient` | ✅ stable |
| **SMPP SMSC** | `127.0.0.1:2775` → OsmoSMSC | SMPP 3.4 (ESME bind/submit) | `sms-client` | ✅ stable |
| **SMS intercept REST** | `POST /api/v1/intercept/sms` (`mvno-api:8080`, host `8080`) | HTTP JSON + `X-API-Key` | `sms-client` (optional) | ✅ stable |
| **Call intercept REST** | `POST|GET /api/v1/intercept/call` (`mvno-api:8080`) | HTTP JSON + `X-API-Key` | `SipClient` (via Kamailio) | ✅ stable |
| **Subscriber balance REST** | `GET /api/v1/intercept/subscriber/{msisdn}` | HTTP JSON + `X-API-Key` | NOC / teammates | ✅ stable |
| **AI classifier (demo)** | `mvno-ai-filter:8000/api/v1/classify` (inline mock, config-only rule) | HTTP JSON | `sms-client` classifier is OPTIONAL | ✅ mock-authoritative |

The inline mock (defined in `docker-compose.yml`) is the **authoritative classifier
for the demo**: it returns `allow:false` / `reason:"Spam (E2E deterministic block)"`
whenever the request body contains the marker `E2E-BLOCK`, else `allow:true`
(`reason:"Clean content"`). The e2e runbook's AI-block cell (Goal 7) asserts this
path. The mock also parses `Transfer-Encoding: chunked` bodies (Spring `RestClient`
sends chunked, without `Content-Length`); a real FastAPI classifier handles chunked
natively and needs no such workaround.

**Auth:** all `/api/v1/intercept/**` endpoints require header `X-API-Key: mvno-demo-key-2026`
(override via `intercept.api-key` / `X_API_KEY` env). Missing/mismatched → `401 Unauthorized`.

---

## 2. Per-repo integration notes (read-only — teammate-side changes are THEIR call)

> **Verified against cloned sources on 2026-08-03** (read-only clones of
> `github.com/AI-SpamFilter-PMN/sms-client` and `.../SipClient`); findings below
> marked ✅-verified or ⚠-mismatch. MVNO still never edits teammate repos.

### SipClient (`com.sipclient.sip.config.SipConfig`) — ✅ verified
- `SipConfig` hardcodes `SERVER_PORT = 5060`, `LOCAL_PORT = 5070` (confirmed in
  source). Ships targeting `SERVER_PORT = 5060`, local `127.0.0.1:5070`.
- **MVNO Kamailio host port is `5066`** (canonical). Host `5060` is occupied by a host-level
  Asterisk (see `docs/ENVIRONMENT_MATRIX.md` §3) — the optional `MVNO_PUBLISH_5060` extra
  publish is **default-off and blocked on this host**.
- **Recommendation to the teammate (not an MVNO edit):** set the SIP server port to `5066`
  (or make it configurable) so the unmodified client reaches Kamailio.

### sms-client (`src/main/resources/application.properties`) — ✅ verified
- `smpp.host=127.0.0.1`, `smpp.port=2775`, `smpp.systemId=smsclient`, `smpp.password=password`
  → **matches MVNO's published SMPP + the `esme smsclient` route in `osmo-smsc.cfg`** ✅.
- `ai.classify.url=http://localhost:5000/classify` — ⚠ **mismatch confirmed in
  source**: matches **no** MVNO endpoint (MVNO mock is `ai-filter:8000/api/v1/classify`;
  `AI-Filteration-System` is `:8000/api/filter-sms`).
  → **Recommendation to the teammate:** point `ai.classify.url` at the agreed classifier, OR
  rely on MVNO's post-submit SMSC interception instead of client-side classification (the two
  are redundant architectures — MVNO enforces allow/block AFTER SMPP submission via the gateway).
- `server.port=8080` ⚠ overlaps `telecom-api`'s `8080` if co-hosted — run on a different host/port.
- `sms.blockSpam=false` default: spam is NOT blocked client-side; MVNO policy gateway still enforces.

### AI-Filteration-System (`ai-model.py`) — endpoint documented, repo private (not verifiable)
- FastAPI at `:8000/api/filter-sms`, requires `API_KEY` + `MODEL_ID` (routes to agentrouter.org).
- For the MVNO demo the **inline `mvno-ai-filter` mock is authoritative** and now
  implements a **deterministic AI-block rule** (`E2E-BLOCK` marker → `allow:false`),
  added config-only in `docker-compose.yml` and **verified end-to-end** by the Goal 7
  `e2e_runbook.sh` AI-block cell (Kamailio 403 + `mvno_sms_blocked_total` increment,
  two consecutive green runs). No external classifier or API key is required.

---

## 3. Optional `MVNO_PUBLISH_5060` (default-off, env-gated)

- A teammate `SipClient` that hardcodes `5060` can be accommodated **only on hosts where UDP 5060
  is free** by publishing an extra `5060:5060`. This is **default-off** and **blocked on this host**
  (Asterisk owns `0.0.0.0:5060`). Enable via compose env when the host is clean.
- `scripts/preflight.sh` checks `ss -lun | grep :5060` and warns loudly if occupied.

---

## 4. MVNO-side stability guarantee

MVNO keeps these seams stable across changes so teammate clients keep working without edits:
- `POST /api/v1/intercept/sms`, `POST|GET /api/v1/intercept/call` request/response schemas.
- SMPP `2775` + the `esme smsclient`/`esme mvno-api-route` routes.
- SIP `5066` host port + digest `subscriber` table credentials (`testpass`).

Any breaking change to these is a **coordinated, versioned contract change** communicated to teammates.
