# DB-Changes.md — Data Changes for the Live Production Neon DB

> **Safety contract**: nothing in this file is ever executed automatically
> against the production Neon database. The MVNO flag-for-review pipeline
> writes **only** to the local clone (`mvno-neon-local`, port 5433) during
> development. This document is the human-review handoff: it lists the exact
> row-level changes the pipeline produces so a reviewer can apply the
> equivalent statements on live Neon after approval.
>
> Production URL: `NEON_DB_URL` (`.env`, git-ignored). Local mirror:
> `NEON_DB_LOCAL_URL` (default `postgresql://mvno:mvno@127.0.0.1:5433/neondb`).
>
> Row-only policy (per `docs/partner/sms-client-INTEGRATION.md`): we add/read
> rows with the EXISTING schema only — never `CREATE`/`ALTER`/`DROP`, never
> change the ERD (`db/schema.sql` lives in the sms-client repo). Message bodies
> and call transcripts are **intentionally NOT stored** — classification
> metadata only. Transcripts/audio live on the MVNO evidence store
> (`state/review/<recording_id>/`).

---

## 1. What changed in this session

| Area | Change | Where |
|------|--------|-------|
| Vosk ASR model | `vosk-model-small-en-us-0.15` → `vosk-model-en-us-0.22` (1.2 GB) | `docker-compose.yml` mount + `VOSK_MODEL_PATH` env + `application.yml` default |
| Voice verdicts | New `mvno.vosk.flagged` counter (blocked ⇒ also flagged) | `NativeVoskService.java` |
| Flag pipeline | `scripts/review/flag_call.sh` — evidence + manifest + local-Neon rows | new |
| Flag watcher | `scripts/review/flag_watch.sh` — tails api verdict logs | new |
| Local mirror | `mvno-neon-local` (postgres:18-alpine, port 5433) + `scripts/neon/clone.sh` | new |

## 2. Row-level changes the pipeline writes (what to review on Neon)

Schema verified against the production clone (2026-08-09, PostgreSQL 18.4):
`calls(id uuid PK, source, destination, classification_label 'spam'|'ham',
classification_score 0..1, status 'COMPLETED'|'BLOCKED'|'MISSED'|'FAILED'|'IN_PROGRESS',
started_at, ended_at, created_at)` and
`logs(id, event_type, severity 'INFO'|'WARN'|'ERROR', message,
related_message_id uuid → messages(id), related_call_id uuid → calls(id),
created_at)`. The docs' "related ids" is really **`related_call_id`** (FK to
`calls.id`), and flagged calls belong in the dedicated **`calls`** table.

### 2.1 `calls` — one classification row per flagged call

```sql
INSERT INTO calls (source, destination, started_at, ended_at,
                   classification_label, classification_score, status)
VALUES ('<caller_msisdn>', '<callee_msisdn>', now(), now(),
        'spam', 0.92, 'BLOCKED')
RETURNING id;   -- keep this UUID: it links the logs row below
```

- `status='BLOCKED'` + `classification_label='spam'` = the AI filter verdict
  (allow:false). The **edge behavior** is flag-for-review — the call was never
  interrupted (post-call classification), and no subscriber is marked by default.

### 2.2 `logs` — VOICE_CALL_FLAG (one row per flagged call)

```sql
INSERT INTO logs (event_type, severity, message, related_call_id)
VALUES (
  'VOICE_CALL_FLAG',
  'WARN',
  'potential scam call flagged for review: caller=<msisdn> callee=<msisdn> imsi=<imsi>',
  '<call_id_from_2.1>'
);
```

- `event_type='VOICE_CALL_FLAG'` is a new value (column is varchar(40), no enum
  check — safe to add; matches the existing `VOICE_BLOCKED_CACHE` family).
- `severity='WARN'` (existing enum value).
- `message` = metadata only — **no transcript text, no call audio**.
- `related_call_id` links the evidence store: `state/review/<recording_id>/`
  (transcript/audio/pcap kept on the MVNO side).

### 2.3 `blocklist` — optional MSISDN mark (only when `FLAG_AUTO_MARK=1`)

```sql
INSERT INTO blocklist (msisdn, reason, expires_at)
VALUES ('<caller_msisdn>', 'potential scam (voice transcript)', now() + interval '30 days')
ON CONFLICT (msisdn) DO UPDATE
  SET reason = EXCLUDED.reason, expires_at = EXCLUDED.expires_at;
```

- **Default OFF** (`FLAG_AUTO_MARK=0`): the edge flags for review but does NOT
  mark subscribers. Marking is the Filteration-System/admin decision.
- `expires_at` = 30-day window; auto-expires unless renewed.

### 2.4 `subscribers.status` — NOT written by the pipeline

Suspend/block status is owned by the Filteration-System admins via their UI.
The MVNO edge never flips `subscribers.status` directly.

## 3. Verified against the local clone

Synthetic pipeline verification run — 2026-08-09 (both rows produced by
`scripts/review/flag_call.sh` writing to the **local clone only**):

```sql
-- calls row (rig-map identity: recording id embedded 10.89.0.61 → caller 15553332211)
INSERT INTO calls (...) VALUES ('15553332211','unknown','spam',0.92,'BLOCKED')
RETURNING id;  -- 42bd6f19-3e97-46cb-b074-7b805c6682d8
-- created_at: 2026-08-09 11:36:03.23553+00

-- logs row (FK linked)
-- id 449 | VOICE_CALL_FLAG | WARN
-- 'potential scam call flagged for review: caller=15553332211 callee= imsi='
-- related_call_id: 42bd6f19-3e97-46cb-b074-7b805c6682d8 | created_at: 2026-08-09 11:36:03.387215+00
```

The clone also holds the untouched production mirror (read-only dump restored
2026-08-09, e.g. `calls` row `56689c8b-…` `01204624374 → 01556701043` ham
COMPLETED) — confirming the insert targets the same schema as live Neon
(PostgreSQL 18.4). `calls.status` enum includes `BLOCKED`;
`logs.related_call_id` FK → `calls.id`; `blocklist` has `msisdn UNIQUE` +
`expires_at`.

## 4. How to apply on production (human, after approval)

1. Review the statements in §2 against the sms-client schema
   (`db/schema.sql` in the sms-client repo).
2. Apply via any Postgres client with `NEON_DB_URL` (e.g.
   `podman run --rm docker.io/library/postgres:18-alpine psql "$NEON_DB_URL"`).
3. Never run the MVNO pipeline itself against production — it is
   hard-wired to the local clone only.
