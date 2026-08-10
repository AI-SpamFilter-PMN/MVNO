# Whole-Project Correctness & Re-consolidation Audit — 2026-08-10

> Scope: MVNO repo (docs ↔ code/compose/Makefile reconciliation, SVG/flow-number
> correctness, edge-case deep-run, and an adversarial self-audit of the committed
> evidence). Read-only audit; findings only (no code changes proposed here).
> Base: `main` = `41cb3eb` (untouched). Branch: `feature/audit-reconciliation-2026-08-10`.

---

## 1. High-level verdict

The stack and the *authoritative* artifacts (compose, live_tap codec dispatch,
Kamailio 403 logic, subscriber DB, actuator metrics, user-demo orchestration) are
**internally consistent and verified live**. The main problems found are
**STALE container-count figures** in three docs (understate the true 34-service
compose) and **two SVG diagrams that omit the newly-added `filteration-system`
voice decider** (staleness, not wrong numbers). No fabricated components, no wrong
IPs/ports/MSISDNs in the authoritative paths. The committed Phase-1/2 evidence is
**honest (not overstated)** — both docs explicitly disclose their key caveats.

---

## 2. FINDINGS (severity-ranked)

### HIGH — Stale container-count claims (3 docs understate the true 34-service compose)

| Doc:line | Claim | Ground truth |
|---|---|---|
| `docs/ENVIRONMENT_MATRIX.md:55` | `# 31 containers, offline-first` | compose now defines **34 services** (`podman compose config --services` = 34); current running set includes `filteration-system` |
| `docs/TESTING_REFERENCE.md:72` | `# expect 31/31 containers Up` | **34** compose services; live `podman ps` shows 36 (34 compose + baresip-rx/tx rig) |
| `docs/deployment_guide.md:83` | `canonical ... base (32 services, statically pinned IPs)` | **34** services |

The 31/32 figures predate the `filteration-system` service added in
commit `a2037d8` (and any intervening drift). This is an **understatement** —
docs claim fewer services than the stack actually has.

### MED — SVG diagrams omit the new `filteration-system` voice decider (staleness, not wrong numbers)

- `docs/architecture_flow.svg`: step **"7. AI Classify"** points only to
  `AI Spam Model Server · POST /api/v1/classify · HTTP 8000`. There is **no
  `filteration-system` node and no `telecom-api → filteration-system POST
  /api/v1/voice/filter` edge** — but `FILTERATION_VOICE_URL=http://filteration-system:8000/api/v1/voice/filter`
  and `AiFilterService.tryVoiceFilter` call the voice-filter contract first.
  Impact: the diagram understates the classification path (voice-filter is the
  primary decider; `/api/v1/classify` is the fallback).
- `docs/ims_voice_call_flow.svg` (otherwise **ACCURATE**, PNG byte-identical):
  step **"11 POST /classify"** should note the voice-filter-first path; the
  `:8000` internal label is correct (not a port error). Minor.
- Stale PNG rasters: `architecture_flow.png` and `sms_interception_flow.png` do
  **not** match their current (Aug-03-edited) SVG sources (MD5 mismatch on
  re-render). `ims_voice_call_flow.png` **is** byte-identical to its SVG. MED.

### LOW / cosmetic — SVG numbering

- `architecture_flow.svg` sequence runs `1,2,3,4,5,6 → 6b,6c → 7` with **no
  step `6a`** and an unnumbered trailing "Metrics" label. Cosmetic only.

### LOW (corrected from deep-run) — caller divergence in the device doc vs user_call.sh

- `docs/device-registration-linphone-mizudroid.md` narrates a **physical
  Linphone/MizuDroid device** registering/calling as **`15551234567` →
  `15559998888`**. `scripts/demo/user_call.sh` instead drives the **baresip-tx
  rig as caller `15553332211` → `15559998888`** (default). Both target
  `15559998888`, but the automated user-call path's caller MSISDN (`15553332211`)
  differs from the device doc's caller (`15551234567`). This is **intentional**
  (the doc describes the human phone path; `user_call.sh` the rig/automated path)
  but the docs should state the distinction explicitly so the "caller" is not read
  as inconsistent.

---

## 3b. Self-corrections (from the adversarial deep-run — auditing my own audit)

The following were **errors/inaccuracies in earlier operator/agent narration**,
caught by the read-only deep-run. Recorded so the record is not overstated:

- **"Graduation EXIT=2 / -91 dB mic failure"** is **inaccurate to the source**.
  `mic_probe.sh` uses `VOLUME_DB_THRESHOLD="-50"` and `mic_verify.sh`/`mic_probe.sh`
  exit `fatal` with code **1**, never **2**; no `-91` or `exit 2` exists. The
  correct behavior: interactive silent-mic → exit 1; `MVNO_MIC_SOFT=1` → exit 0
  benign. `MVNO_MIC_SOFT` is a **tolerance on the assertion of a genuine capture**,
  **not** "not a real capture" — it does not make the mic capture fake.
- **"26 compose services" / "31/32 containers"** are all **stale**. The current
  truth (live): **34 compose services / 36 running containers** (`34 mvno-*` +
  `baresip-rx` + `baresip-tx`), all Up / none Unhealthy. `filteration-system`
  (10.89.0.65) is live and healthy.

---

## 3. CONFIRMED ACCURATE (explicitly not problems — verified live)

- **Subscriber DB** (`state/kamailio/kamailio.db`): all 6 canonical MSISDNs
  present, correct balances (`15557654321`=0, others=100), none blocked.
  `make check-subs` = **10/10 PASS**. Subscriber topology consistent.
- **Kamailio 403 logic** (`kamailio.cfg:185/205`): blocks call/SMS only when
  `allow=false` from `mvno-api:8080/api/v1/intercept/{call,sms}` — gated on
  the zero-balance (15557654321) verdict, matching the SMS SVG "Kamailio 403".
- **rtpengine**: `port-min=30000` (30000-30100), `listen-ng=0.0.0.0:22222`,
  `recording-method=pcap`, `recording-dir=/var/spool/rtpengine` — matches both
  SVGs, compose, and the pcap→Vosk proof path.
- **live_tap codec dispatch**: PT 0=G.711u, 8=G.711a, 9=G.722, 111=Opus
  (`dec="-f g722"` wideband) — docs' "codec-aware (G.711u/a, G.722; Opus
  fallback)" is **accurate**.
- **Ports/IPs**: Kamailio 5066→5060 (10.89.0.23), rtpengine 30000-30100+9900
  (10.89.0.48), telecom-api 8080 (10.89.0.46), ai-filter 8008→8000 (10.89.0.44),
  filteration-system 8000 (10.89.0.65), osmo-smsc 2775 (10.89.0.49), ip-sm-gw
  5090/9100 (10.89.0.53), mongodb 27017, VictoriaMetrics 8428, vmagent 8429,
  VictoriaLogs 9428, Grafana 3000, neon-local 5433 — all match compose. No wrong
  port/IP in the authoritative docs/SVGs.
- **USER_DEMO / Makefile**: `make user-demo` menu order (up→probe→sms→call→
  evidence) matches `scripts/demo/user_demo.sh` and `USER_DEMO.md`; caller
  `15551234567` → target `15559998888` consistent with
  `docs/device-registration-linphone-mizudroid.md`.
- **Actuator metrics**: `/actuator/prometheus` returns 200 and exposes
  `mvno_vosk_blocked_total`, `mvno_vosk_scamflag_total` (matches
  `user_demo.sh` evidence → `mvno_vosk_scamflag/flagged/blocked`).
- **Lock hygiene**: no stale `/tmp/mvno-*.lock*` currently (rerun-safe).

---

## 4. Self-audit of the committed evidence (over/understatement check)

### Phase-1 evidence (`docs/evidence/2026-08-09-filteration-system-live.md`, commit `a2037d8`)
- **Verdict: ACCURATE (with an explicitly disclosed caveat).** The doc names the
  service `filteration-system` (which is the literal hostname / compose service),
  but **explicitly states** it is a lightweight `python:3.11-alpine` decider
  implementing the org-documented *deterministic fallback layer*, and that the
  real Spring Boot `Filteration-System` can be swapped in by re-pointing
  `FILTERATION_VOICE_URL`. It does **not** claim the AI/LLM, SMPP, or blocklist
  of the real 5th-repo app. The FINAL-DECLARATION criterion "a real voice-filter
  POST returns a verdict (not fail-open)" is literally satisfied (a reachable
  decider returns `{isMalicious,action}` instead of failing open to allow).
- **Not overstated**: the `mvno_vosk_blocked_total 0→1` counter is real (live
  VictoriaMetrics = 1); `getent hosts filteration-system` resolves (live exit 0);
  scam→`DROP_CALL`, clean→`ALLOW_CALL` re-verified live.
- **Understatement check**: the doc *does* mention the `mvno-telecom-api` rebuild
  (stale image was 2-arg; rebuilt to 4-arg thread-identity + 3-arg tryVoiceFilter).
  Not understated.

### Phase-2 evidence (`docs/evidence/2026-08-09-g722-sip-rtp-path.md` + device doc, commits `fa5fe31`,`9928e16`)
- **Verdict: ACCURATE / honest.** The doc **explicitly discloses** that the sim
  negotiates G.722 (pt 9) in SDP but streams synthetic tone bytes on **pt 0
  (PCMU)** — it does not claim true G.722 bit-stream was carried. It claims the
  **SIP+RTP path + G.722 SDP negotiation** are pre-verified and that "rtpengine
  is codec-agnostic (no transcoding), so the negotiated pt passes through; the
  physical device's G.722 encode + speech is the only unproven link." That claim
  is **justified and not overstated**.
- **Understatement check**: the addendum (commit `9928e16`) also honestly records
  that the rig (baresip-rx) re-offers G.722 at 8k and that the caller-sim exits
  after its `200 OK` parser miss (baresip replies `200 Answering`) — captured in
  the pcap/metadata. Not understated.
- **Device doc cross-check**: caller `15551234567` = funded (bal 100, unblocked)
  per `scripts/lib/common.sh` + live subscriber DB; target `15559998888` =
  baresip-rx auto-answer `<sip:15559998888@10.89.0.23:5060>`; proxy
  `192.168.100.93:5066`, domain `localhost`, `testpass`, UDP — all match live
  ground truth. **ACCURATE.**

---

## 5. Recommended corrective actions (for a follow-up branch — NOT done here)

1. **High:** Update `docs/ENVIRONMENT_MATRIX.md:55`, `docs/TESTING_REFERENCE.md:72`,
   `docs/deployment_guide.md:83` to the true **34-service** compose count (or
   point at `podman compose config --services | wc -l`).
2. **Med:** Add a `filteration-system` node + `POST /api/v1/voice/filter` edge to
   `docs/architecture_flow.svg` (and note it in `ims_voice_call_flow.svg` step 11),
   keeping `/api/v1/classify` as the fallback; add a `host: 8008` annotation for
   `ai-filter`. Regenerate `architecture_flow.png` + `sms_interception_flow.png`
   from their current SVGs.
3. **Low:** Renumber `architecture_flow.svg` (add `6a`, number the Metrics label).

*This audit is evidence-based: figures quoted come from the live running stack,
`podman compose config`, `sqlite3`, `git`, and byte-level SVG render comparison.
`main` (41cb3eb) was not modified.*