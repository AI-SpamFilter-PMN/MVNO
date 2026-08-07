# MVNO Telecom Core — LIVE DEMO (Presentation Script)

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
**This is the demo.** Every block below was verified live (2026-08-06 audit +
evidence-layer runs in `docs/evidence/demo-run-2026-08-07.log` /
`e2e-run-2026-08-07.log`). One terminal (T-B) at the repo root does almost
everything; T-A holds the 2G Mobile Station (MS) for receipts; optional extra terminals are
listed per step. Paste each block **verbatim** and read the EXPECT line.

> **Fallback convention**: every step's FALLBACK points at a seeded fixture in
> `docs/evidence/fixtures/` or a section of `docs/TESTING_REFERENCE.md` (the
> renamed reference) — the demo stays non-empty even if a live component is
> silent. If the **automated** proof is what you need, run `demo_runbook.sh`
> (13 items) + `e2e_runbook.sh` (8 cells) — S10.

Terminal map:

| Terminal | Role | Steps |
|---|---|---|
| **T-A** | 2G MS (`podman exec -it mvno-2g-ms /bin/bash` + `mctest`) | S2, S6 |
| **T-B** | main — host shell at repo root | all others |
| **T-C** | live view: `watch` on spool transcripts + verdicts | S4 |
| **T-G** | playback: `aplay` the archived legs | S4 |

---

## S1 — Stack & Health  ·  ~1 min

**PURPOSE** — prove the stack is up and the host has the demo toolchain.

**CLEAN SLATE (run before every demo re-run)** — prior runs leave baresip
terminals running and live Session Initiation Protocol (SIP) registrations in Kamailio's usrloc (Issue 8.37)
that mask the bounded-retry and 404 flows. Reset first:

```bash
podman rm -f baresip-rx baresip-tx 2>/dev/null
for u in 15559998888 15557654321 15554443322 15557778888; do
  python3 scripts/testing/sip_traffic_sim.py --callee $u --deregister
done
sqlite3 state/kamailio/kamailio.db "DELETE FROM location WHERE expires < julianday('now');"
```

**EXPECT** — `SIP DEREGISTER 200 OK` per user; `location` holds only the rigs
you registered this session.

**COMMANDS**

```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
for t in sqlite3 curl espeak-ng ffmpeg nc tshark xxd md5sum aplay ffprobe; do
  command -v $t >/dev/null || echo "MISSING: $t"
done
podman compose ps | grep -c Up          # expect 31 (containers of the stack)
curl -s http://localhost:8080/actuator/health | head -c 80
```

**EXPECT** — no `MISSING` lines; 31 `Up`; actuator health JSON contains `"UP"`.

**MIC SELF-TEST (2 s)** — proves the full live-speech path (mic → 16 kHz WAV →
`NativeVoskService` → transcript) before the scam-call demo depends on it:

```bash
bash scripts/testing/mic_record.sh 2
sleep 4
ls -la state/spool/archived/mic_call_*.txt | tail -1
cat $(\ls -t state/spool/archived/mic_call_*.txt | head -1)
```

**EXPECT** — a non-empty transcript line (what you just spoke; English words are
most reliable). If the Vosk offline speech engine is unavailable the demo still proceeds — transcripts
are demo-grade, the AI verdicts come from the REST/Short Message Service (SMS) paths.

**FALLBACK** — fixtures: `docs/evidence/fixtures/MANIFEST.md` (45/45 checksummed
reference transcripts/verdicts, no mic required).

**FALLBACK** — stack gates: `docs/TESTING_REFERENCE.md` §Prerequisites;
`./scripts/preflight.sh` auto-verifies the host.

---

## S2 — Attach the 2G MS (keep this terminal)  ·  ~1 min

**PURPOSE** — the 2G receipt reader (MS1 / `15554443322`, IMSI
`001010000000004`); every 2G-received SMS lands in
`/root/.osmocom/bb/sms.txt`.

**COMMANDS** (T-A)

```bash
podman exec -it mvno-2g-ms /bin/bash
cd /tmp && ./mctest -l /tmp/osmocom_l2 -P mm    # bring up MM layer toward MSC
```

**EXPECT** — `mctest` shows MM-layer bring-up toward the MSC; leave this
terminal attached for the whole demo (S6a/6c receipts). Drop back with `exit`
after S2 — Steps S3+ run on the **host** (T-B).

**FALLBACK** — 2G path details: `docs/TESTING_REFERENCE.md` Flow A.

---

## S3 — Real Call + Speak the Scam Script + RTPEngine (media proxy) Bytes  ·  ~3 min

**PURPOSE** — a real `baresip` voice call, auto-answered, media through
RTPEngine; the **callee streams a canned scam phrase**, the **caller can speak
live** (pulse). RTPEngine records a pcap per call.

**COMMANDS** (T-B)

```bash
bash scripts/testing/demo_call.sh setup    # speech file + baresip UAs, both register (~15 s)
bash scripts/testing/demo_call.sh dial     # real call: callee streams the scam phrase; TALK NOW for ~12 s
podman logs baresip-rx | grep -c "200 Answering"   # expect 1
\ls -t state/spool/pcaps/*.pcap | head -1           # the fresh recording (~450 KB)
curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_packets_total'
```

**EXPECT** — `dial` prints `CALL_OUTGOING → CALL_RINGING → CALL_ANSWERED →
CALL_ESTABLISHED → CALL_RTPESTAB → CALL_CLOSED`; `200 Answering` = 1; a new
pcap (~450 KB) in `state/spool/pcaps/`; RTPEngine counters present.

**FALLBACK** — mic silent? `docs/TESTING_REFERENCE.md` §Mic pre-flight + canned
`ausine` fallback (replace `pulse` lines); sim-based call variant:
`docs/TESTING_REFERENCE.md` Flow E (T6/T7/T8); rig mechanics (baresip configs,
mounts, ctrl-socket framing): `docs/TESTING_REFERENCE.md` §Raw mechanics.

---

## S4 — live_tap → WAV → ffprobe → aplay → Vosk Transcript  ·  ~2 min

**PURPOSE** — extract the recorded call with the zero-Python pipeline
(`live_tap.sh --once`: per-src-IP legs, RTCP dropped, 16 kHz out) and show the
Vosk transcript + AI verdict land in the spool.

**COMMANDS** (T-B; optional T-C live view)

```bash
# T-C (optional, recommended): watch transcripts + verdicts appear live
watch -n2 'cat state/spool/archived/live-caller.txt state/spool/archived/live-callee.txt 2>/dev/null; podman logs --since 5m mvno-api 2>/dev/null | grep "AI transcript verdict" | tail -2'
```

```bash
# T-B — extract the newest recorded call (Tier-3, --once)
NEW=$(\ls -t state/spool/pcaps/*.pcap | head -1)
bash scripts/testing/live_tap.sh --once "$NEW"
ffprobe -v error -show_entries format=duration -of csv=p=0 \
  state/spool/archived/live-caller.wav        # >= 3s (scripted-leg floor)
aplay state/spool/archived/live-caller.wav    # hear the caller leg
sleep 12                                      # Vosk watcher (~3s poll) does its work
cat state/spool/archived/live-caller.txt state/spool/archived/live-callee.txt
podman logs mvno-api 2>&1 | grep "AI transcript verdict" | tail -4
```

**EXPECT** — `WAV extracted` per leg; ffprobe ≥ 3 s; `aplay` plays the archived
leg; transcripts = callee `"you have won a prime target now"` (canned phrase
fuzz) + caller = your distinct spoken words; verdicts
`[live-caller]: allow=true, 'Clean content'` and
`[live-callee]: allow=false, 'Spam (phishing phrase detected)'`.

**FALLBACK** — fixtures guarantee non-empty evidence regardless of live audio:
`docs/evidence/fixtures/archived/live-385288b…-10.89.0.60-0.{wav,txt}` (callee,
"you have won a prize called target now") and `live-caller.{wav,txt}` (17.9 s
real voice); extraction details: `docs/TESTING_REFERENCE.md` Flow M.

---

## S5 — Real-Speech BLOCKED Verdict  ·  ~1 min

**PURPOSE** — the recorded scam phrase is classified as spam and **blocked** by
the AI interception core; the counter proves it.

**COMMANDS** (T-B)

```bash
curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total'
# -> "value":[<epoch>,"<N>"] — note N BEFORE, then replay the fixture below
cp docs/evidence/fixtures/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.60-0.wav \
  "state/spool/demo-real-$(date +%s).wav"
sleep 12
cat state/spool/archived/demo-real-*.txt                 # "you have won a prize called target now"
podman logs mvno-api --since 2m | grep "AI transcript verdict" | tail -2
curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total'
```

**EXPECT** — the fixture transcript contains "won"/"prize" → verdict
`allow=false, reason='Spam (phishing phrase detected)'` and
`mvno_vosk_blocked_total` **increments** (the same 1→2 delta the certified
`demo_runbook.sh` [9b] asserts).

**FALLBACK** — deterministic SIP-side block (E2E-BLOCK → 403):
`docs/TESTING_REFERENCE.md` Flow K; automated variant: `demo_runbook.sh` item 9b.

---

## S6 — The Four SMS Paths (A: 2G→2G, B: 2G→5G, C: 5G→2G, D: 5G→5G)  ·  ~5 min

**PURPOSE** — every messaging path the core implements, raw and observable.
Keep T-A attached (S6a/6c receipts land in its `sms.txt`).

**S6a — 2G→2G (raw binary Short Message Peer-to-Peer (SMPP) over nc, port 2775)**

**COMMANDS** (T-B)

```bash
python3 scripts/testing/send_raw_smpp.py 15557778888 15554443322 "Hello raw 2G2G"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```

**EXPECT** — `SMPP BIND_TRANSCEIVER Successful` + `SUBMIT_SM accepted
(ESME_ROK)`; MS1 prints `[SMS from +15557778888]` / `Hello raw 2G2G`. Bridge
counters stay flat (not involved).

**S6b — 2G→5G (row into the bridge's polled queue)**

```bash
python3 scripts/testing/inject_smsc_row.py 15554443322 15559998888 "Hello raw 2G5G"
sleep 8
podman logs mvno-ip-sm-gw --since 2m | grep -E "POLL|DELIVERED" | tail -2
podman logs baresip-rx 2>&1 | grep "Hello raw 2G5G"        # MESSAGE body seen
```

**EXPECT** — bridge `[POLL] row_id=NN …` → `[DELIVERED] row_id=NN marked sent`;
Kamailio relays; baresip-rx prints the body. Cleanup afterwards so the gates
aren't polluted: `sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"`.

**S6c — 5G→2G (digest-auth SIP MESSAGE via Kamailio 5066)**

```bash
python3 scripts/testing/send_digest_sms.py 15553332211 15554443322 "Hello raw 5G2G"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```

**EXPECT** — `SIP/2.0 200 OK`; bridge `[RELAY] 5G->2G …` + `[SMPP] BIND_TRANSCEIVER
OK` + `[SMPP] SUBMIT_SM OK`; MS1 prints `[SMS from +15553332211]` /
`Hello raw 5G2G`. (MS2 trap: an SMS to `15557778888` is accepted but never
receipted — the 2G container serves only MS1; always use `15554443322`.)

**S6d — 5G→5G (digest-auth SIP MESSAGE to the registered IMS number)**

```bash
python3 scripts/testing/send_digest_sms.py 15553332211 15559998888 "Hello raw 5G5G"
sleep 8
podman logs baresip-rx 2>&1 | grep "Hello raw 5G5G"        # body received
```

**EXPECT** — `SIP/2.0 200 OK`; baresip-rx prints the body — pure IMS SMS, no
bridge/SMPP (counters stay flat).

**FALLBACK** — per-path detail + terminal setups: `docs/TESTING_REFERENCE.md`
Flows A–D; raw PDU (Protocol Data Unit)/digest/rig mechanics (the original inline commands):
`docs/TESTING_REFERENCE.md` §Raw mechanics; scripted SMPP variant: S7.

---

## S7 — SMPP (scripted SUBMIT_SM + stored row)  ·  ~1 min

**PURPOSE** — the same SMPP 3.4 channel via the harness, ending with the SMS
row provably stored in the SMSC DB (terminal evidence).

**COMMANDS** (T-B)

```bash
python3 scripts/testing/send_smpp_sms.py          # bind + SUBMIT_SM 15551234567 -> 15557654321
sqlite3 -header -column state/hlr/smsc.db \
  "SELECT id, src_addr, dest_addr, substr(text,1,40) AS content, created, sent FROM SMS ORDER BY id DESC LIMIT 5;"
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"   # drain (gate hygiene)
```

**EXPECT** — `BIND_TRANSCEIVER Successful` / `SUBMIT_SM Delivered` /
`Status=0x00000000` (ESME_ROK); the dump shows the row with
`src_addr=15551234567, dest_addr=15557654321` and its body.

**FALLBACK** — PDU byte anatomy + injector internals:
`docs/TESTING_REFERENCE.md` §Injectors + Flow B; automated: `demo_runbook.sh` items 10/10b.

---

## S8 — REST API + smsc DB Dump  ·  ~1 min

**PURPOSE** — the gateway interception API: clean content allowed, spam marker
blocked; then the terminal evidence dump of the SMSC store.

**COMMANDS** (T-B)

```bash
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender": "15551234567", "recipient": "15557654321", "content": "Hello MVNO 5G"}'
# -> {"allow":true,"reason":"Clean content"}
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender": "15551234567", "recipient": "15557654321", "content": "E2E-BLOCK REST test"}'
# -> {"allow":false,"reason":"Spam (E2E deterministic block)"}
sqlite3 -header -column state/hlr/smsc.db \
  "SELECT src_addr, dest_addr, substr(text,1,40) AS content, sent FROM SMS ORDER BY id DESC LIMIT 5;"
```

**EXPECT** — two verdicts (allow true/false); the smsc.db dump shows the stored
SMS rows (real terminal evidence, non-empty).

**FALLBACK** — API schema: `docs/TESTING_REFERENCE.md` Flow I + INTEGRATION_CONTRACT.

---

## S9 — PromQL / Grafana  ·  ~1 min

**PURPOSE** — telemetry: the interception counters live in VictoriaMetrics and
the Network Operations Center (NOC) dashboard renders.

**COMMANDS** (T-B)

```bash
for q in mvno_call_requests_total mvno_vosk_classified_total mvno_vosk_blocked_total mvno_sms_blocked_total; do
  curl -s "http://localhost:8428/api/v1/query?query=$q" | grep -o '"value":\[[0-9]*,"[0-9]*"\]'
done
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/login   # 200
```

**EXPECT** — every counter returns a `"value":[<epoch>,"<N>"]` tuple (N ≥ 1 for
the call/classified counters after S3–S5); Grafana login HTTP 200.

**FALLBACK** — dashboard JSON: `docs/evidence/grafana-mvno-unified-noc.json`;
details: `docs/TESTING_REFERENCE.md` Flow J.

---

## S10 — Runbook Gates  ·  ~15 min

**PURPOSE** — the automated proof: e2e SMS matrix (5 cells / 8 ok) then the
full 13-item demo, both exiting 0, both teed to `docs/evidence/` logs.

**COMMANDS** (T-B)

```bash
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"   # drain leftover demo rows
./scripts/testing/e2e_runbook.sh ; echo "exit=$?"                 # ALL CELLS PASS, exit=0
./scripts/testing/demo_runbook.sh ; echo "exit=$?"                # ALL 13 PASSED, exit=0
podman rm -f baresip-rx baresip-tx        # demo cleanup
```

**EXPECT** — `E2E RUNBOOK: ALL CELLS PASS (8 ok)` / `exit=0`; demo
`ALL 13 DEMO ITEMS PASSED` / `exit=0`; fresh `docs/evidence/e2e-run-2026-08-07.log`
and `demo-run-2026-08-07.log` (each run appends its day's file).

**FALLBACK** — gate internals: `docs/TESTING_REFERENCE.md` Flows L & N;
failure-path checks: Flow O.
