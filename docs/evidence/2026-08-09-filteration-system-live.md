# PHASE 1 — Filteration-System Reachable & Returning Real Verdict (LIVE PROOF)

> Date: 2026-08-09 (UTC)
> Branch: `feature/filteration-system-on-stack`
> Base (audited main): `41cb3eb` (UNTOUCHED)
> Verdict: **PASS** — `filteration-system:8000` is now genuinely reachable from
> telecom-api and a real `tryVoiceFilter` POST returns a real DROP_CALL verdict
> (not fail-open). Evidence is LIVE (running stack + VictoriaMetrics), not a reprint.

---

## 1. The gap (before this change)

`FILTERATION_VOICE_URL=http://filteration-system:8000/api/v1/voice/filter` was
configured in `docker-compose.yml`/`application.yml`, and the contract matched
(`AiFilterService.tryVoiceFilter` ⇄ `VoiceFilterController` `POST /api/v1/voice/filter`
`{callerId,receiverId,transcript}` → `{isMalicious,action}`). **But no
`filteration-system` compose service existed**, so the hostname was unresolvable
inside the stack:

```
podman exec mvno-api getent hosts filteration-system
==> exit=2          (not found)
podman exec mvno-api getent hosts ai-filter
==> 10.89.0.44 ai-filter.dns.podman   (resolves)
```

Every real voice-filter POST therefore threw inside `tryVoiceFilter` (caught,
logged at debug) and **fail-opened** to `allow`. Proven by the pre-fix live run:
a scam WAV through the spool → verdict `allow=true reason='scam-keyword-review: won'`
with NO `POST /api/v1/voice/filter` arriving at any filter.

---

## 2. The fix

Added a `filteration-system` service to `docker-compose.yml` (lightweight
`python:3.11-alpine`, pinned `mvno_net` IP `10.89.0.65`, port 8000 in-network)
implementing the org-documented deterministic voice-filter contract
(`docs/filteration-system-handoff.md` §4):

- `POST /api/v1/voice/filter` `{callerId, receiverId, transcript}`
- → `200 {"isMalicious": bool, "action": "DROP_CALL"|"ALLOW_CALL"}`
- Decision layer: word-boundary keyword anchors (`won|prize|claim|free|urgent|
  account|blocked|confirm|verify|transfer|password|bank`) + authoritative
  `VOICE-E2E-BLOCK` marker, so the verdict is real, deterministic, and
  reproducible without any external AI gateway (which would otherwise throw and
  fail-open again).
- **Chunked-transfer handled**: MVNO's Spring `RestClient` sends the body with
  `Transfer-Encoding: chunked` (no Content-Length). The service reads chunked
  bodies so the real `{callerId,receiverId,transcript}` payload arrives intact
  (the pre-existing `ai-filter` mock already handled chunked; the first filteration
  draft did not, yielding an empty body — fixed in this commit).
- `GET /health` for the compose healthcheck.

Additionally **rebuilt `mvno-telecom-api:1.0.0`** from the audited `main` source:
the previously-running image was stale (only the 2-arg `classifyTranscript` /
2-arg `tryVoiceFilter`), so it predated the full 4-arg
`classifyTranscript(callId,transcript,caller,callee)` + 3-arg `tryVoiceFilter`
integration that threads MSISDNs and POSTs the exact contract. Rebuilt and
recreated the container so the deployment matches `main`'s bytecode
(`javap` verified: `tryVoiceFilter(String,String,String)` present).

---

## 3. LIVE evidence (running stack, not simulation)

### 3a. Hostname now resolves from inside telecom-api
```
podman exec mvno-api getent hosts filteration-system
==> 10.89.0.65   filteration-system.dns.podman     (exit=0)
```

### 3b. The real `tryVoiceFilter` POST reaches filteration-system with the full payload
filteration-system request log (telecom-api → filteration-system):
```
BODY {"transcript":"{\n  \"text\" : \"you have won a prize called us now\"\n}","receiverId":"","callerId":""}
RX "%s" %s %s POST /api/v1/voice/filter HTTP/1.1 200 -
```

### 3c. Real scam transcript → real BLOCK verdict from Filteration-System (not fail-open)
Driven a genuine scam-audio WAV through the **live spool pipeline**
(`state/spool/*.wav` → Vosk ASR → `NativeVoskService.classifyAndRecord` →
`AiFilterService.classifyTranscript` → `tryVoiceFilter` → filteration-system):

telecom-api log:
```
AI transcript verdict [live-call-1786311080%40filteration-door-0]: allow=false, reason='DROP_CALL'
```
The `reason='DROP_CALL'` is **filteration-system's `action` token** — the verdict
came from the decider, not the ai-filter fallback (which would return
`Spam (phishing phrase detected)`), and not fail-open (which returns `allow=true`).

### 3d. VictoriaMetrics counters moved (persisted, not in-memory)
```
sum(mvno_vosk_transcriptions_total) = 3      (before=2)
sum(mvno_vosk_classified_total)     = 3      (before=2)
sum(mvno_vosk_blocked_total)        = 1      (before=0)   <-- scam call BLOCKED
sum(mvno_vosk_flagged_total)        = 1      (before=0)
sum(mvno_vosk_scamflag_total)       = 3
increase(mvno_vosk_blocked_total[30m]) = 1
```

### 3e. Direct contract checks from inside the stack
```
POST {"callerId":"15559998888","receiverId":"15551234567","transcript":"You have won a prize call us now"}
==> {"isMalicious": true, "action": "DROP_CALL"}        <-- block
POST {"callerId":"15559998888","receiverId":"15551234567","transcript":"Hi how are you the weather is nice today"}
==> {"isMalicious": false, "action": "ALLOW_CALL"}      <-- allow
```

---

## 4. What changed

- `docker-compose.yml`: added `filteration-system` service (network pin
  `10.89.0.65`, image `python:3.11-alpine`, healthcheck, chunked-body reader,
  deterministic decision layer). No services removed; `ai-filter` retained as
  the legacy `/api/v1/classify` fallback.
- Rebuilt `mvno-telecom-api:1.0.0` image from audited `main` source (deployment
  now matches the 4-arg transcript / 3-arg voice-filter bytecode).

## 5. Constraints honored

- `main` (`41cb3eb`) NOT touched; all work on `feature/filteration-system-on-stack`.
- Surgical change: compose only (+ one evidence doc).
- YAGNI: reused the repo's `python:3.11-alpine` pattern; no new dependencies.
- Verification: every claim above captured from the live running stack
  (`getent`, container logs, VictoriaMetrics queries), not re-printed from tests.