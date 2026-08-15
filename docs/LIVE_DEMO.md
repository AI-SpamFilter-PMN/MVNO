# MVNO Core — LIVE DEMO (Presentation Script)

> **Abbreviations**: `docs/GLOSSARY.md` is the single source of truth. Every
> block below was **verified live against the running stack** (2026-08-08);
> automated proof = `live_demo.sh` (13 items) + `sms_matrix.sh` (8 cells)
> — S10. One terminal (T-B) at the repo root does almost everything; T-A holds
> the 2G Mobile Station (MS) for receipts. Paste each block **verbatim** and read
> the EXPECT line.

**Terminal map** (open as many as useful — live evidence shows in them):

| Terminal | Role | Steps |
|---|---|---|
| **T-A** | 2G MS (`podman exec -it mvno-2g-ms /bin/bash`, auto-attached, watch `sms.txt`) | S3, S6 |
| **T-B** | main — host shell at repo root | all others |
| **T-C** | live view: `watch` transcripts + verdicts + container logs | S2, S5 |
| **T-G** | playback: `aplay` the archived legs | S5 |
| **T-M** | metrics: `watch` the PromQL counters | S7, S9 |

> **One-shot cockpit**: instead of juggling T-A..T-M by hand, `bash
> scripts/demo/demo_live.sh` opens all of them as a tmux session (S11).

---

## 🎯 Supervisor Quick-Start Executive Runbook (0-Cold-Start to Complete Live Demo)

When demonstrating the project live to your academic or technical supervisor, execute these 5 high-impact stages in order:

### Stage 1: Zero Cold-Start Bootstrap (37 Containers Up & Healthy)
```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
make bootstrap
# ≡ make init-db -> make up -> make seed-mongo -> make bootstrap-check (8/8 functional checks green)
```

### Stage 2: Full Bidirectional Matrix E2E Test (12/12 Automated Suite)
```bash
python3 scripts/testing/bidirectional_matrix_e2e.py
# Runs all 12 permutations: 2G<->2G, 2G<->5G, 5G<->5G, AI Phishing Block, ConfBridge 7001, IVR 8000, and Linphone!
```

### Stage 3: Live Microphone Capture & Real-Time Vosk ASR Transcription
```bash
bash scripts/demo/mic_verify.sh
# 🎙️ Prompts you to speak into laptop microphone -> records WAV -> Native Vosk JNI transcribes -> AI verdict printed!
```

### Stage 4: Physical Android Handset Live Call & ConfBridge Conference
* **Softphone Setup**: Linphone Android on `192.168.100.34` (User: `15551234567`, Domain: `192.168.100.93:5060`).
* **Multi-Party Mixed Conference**: Dial `7001` from the phone to join Asterisk ConfBridge with laptop speaker/mic.
* **Interactive Call Screening IVR**: Dial `8000` to state your name and press `1` to accept.

### Stage 5: Mirrored Local NeonDB & Companion Repositories
* **Local Postgres Mirror**: Running on `127.0.0.1:5433/neondb` (9 tables: `blocklist`, `calls`, `messages`, `users`, `logs`).
* **Admin Dashboard**: Run `admin-client` on `http://localhost:8082` to moderate subscribers and view live call/SMS logs.
* **SMS Portal**: Run `sms-client` on `http://localhost:8083` to send/receive messages via SMPP.

---

## S1 — Bring-Up & Clean Slate  ·  ~2 min

**PURPOSE** — start the stack from cold, configure the host toolchain, and reset
state so every repeat run starts identical.

**BRING-UP** (T-B, once per session — mostly "already Up" on a live box).
On a **fresh box** the order matters — `make up` alone does **not** create the
subscriber DBs or seed Open5GS, so the SMS auth / balance-403 / HLR lookups and
5G UE registration would all fail. The canonical cold-start sequence is:

```bash
make init-db        # SQLite WAL DBs (Kamailio auth + balance, HLR) — idempotent upserts
make up             # image gate + `podman compose up -d` (idempotent)
make seed-mongo     # Open5GS 5G subscriber docs — AFTER up: it execs into the
                    # running mongodb container (without it: UDR "No UE-AMBR" ->
                    # 5G UEs cannot register, gate cell 2 fails)
```
One-command equivalent — `make bootstrap` (≡ `init-db` → `up` → `seed-mongo`
→ `bootstrap-check`, the post-up **functional health gate**). The gate polls
(bounded) that the stack is *functional*, not just Up: Kamailio subscriber
rows, hlr.db IMSI map, Open5GS 3 UEs, API + ai-filter health, unique IP pins,
bridge 2G AoRs, and `ran_ue == 3` — the first red marker names the exact
missing step. `make up` itself now **fails fast** with a guided error if the
subscriber DBs are missing (no more silent broken stack).

```bash
make bootstrap
# or the explicit steps: make init-db && make up && make seed-mongo && make bootstrap-check
```
If `make` isn't available, the compose path is `podman compose up -d` (or
`docker compose up -d`) — but still run `make init-db` and `make seed-mongo`
first (or the equivalent `sqlite3`/`mongosh` steps in `scripts/seed-mongo.sh`).

**Image mode**: if the 8 custom `mvno-*` images are already in local storage,
`make up` launches instantly (offline-first). If they are missing, `up.sh`
auto-falls back to a source build (`docker-compose.build.yml`); a fresh machine
with internet can pre-pull instead: `./scripts/pull-images.sh && make up`.
`make rebuild` = clean teardown + source rebuild (use when the stack misbehaves
at the image/state level). Full details: `docs/deployment_guide.md` §2 / §2B.

**EXPECT** — `Started`/`Up` lines; `podman compose ps | grep -c Up` eventually
returns **36** (34 core + `baresip-rx`/`baresip-tx` — the rig is now
**compose-managed**, so `make up` includes it; no separate demo-only bring-up).
Health can take ~30 s — poll:
```bash
until [ "$(podman compose ps 2>/dev/null | grep -c Up)" -ge 36 ]; do
  sleep 3; printf '.'
done; echo " UP"
```

**HOST TOOLCHAIN** — the demo needs these on the host (probe them):

```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
for t in sqlite3 curl espeak-ng ffmpeg nc tshark xxd md5sum aplay ffprobe jq; do
  command -v $t >/dev/null || echo "MISSING: $t"
done
```
**EXPECT** — no `MISSING` lines. If anything is missing, install it (Debian)
via `sudo apt install sqlite3 curl espeak-ng ffmpeg tshark xxd jq pulseaudio-utils`
(see `docs/deployment_guide.md` §2 for the authoritative list). `espeak-ng` only
matters if you want to re-synthesize the scam script yourself; the canned fixture
ships in the repo.

**CLEAN SLATE** — prior runs leave baresip terminals running and live SIP
registrations in Kamailio's usrloc (Issue 8.37) that mask the bounded-retry and
404 flows. Reset first (idempotent — safe to run already-clean):

```bash
podman compose rm -sf baresip-rx baresip-tx 2>/dev/null
for u in 15559998888 15557654321 15554443322 15557778888; do
  python3 scripts/testing/sip_traffic_sim.py --callee "$u" --deregister
done
sqlite3 state/kamailio/kamailio.db \
  "DELETE FROM location WHERE expires < julianday('now');"
```
**EXPECT** — `SIP DEREGISTER 200 OK` per user (or "not registered", fine);
`location` holds only the rigs you register this session.

---

## S2 — Stack Health & 2G MS Attach  ·  ~1 min

**PURPOSE** — prove the whole interception core answers, then attach the 2G
receipt terminal.

**COMMANDS** (T-B) — actuator + the AI filter + a metrics heartbeat:

```bash
curl -s http://localhost:8080/actuator/health | head -c 120; echo
podman logs mvno-api 2>&1 | tail -2
curl -s http://localhost:8008/ | head -c 20; echo " <- ai-filter alive"
curl -s 'http://localhost:8428/api/v1/query?query=up' | jq -r '.data.result[0].value[1]'
```
**EXPECT** — actuator JSON contains `"UP"`; `ai-filter` returns `OK`; the
`up` metric returns `1`.

> **T-M optional live view** (second terminal): watch interception counters tick
> as the demo runs —
> ```bash
> watch -n2 'curl -s "http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total" | jq -r .data.result[0].value[1]'
> ```

**ATTACH THE 2G MS** (T-A — keep this terminal): the receipt reader
(MS1 / `15554443322`, IMSI `001010000000004`); every 2G-received SMS lands in
`/root/.osmocom/bb/sms.txt`. The MS **auto-attaches at container start**
(PID 1 runs `mobile -c /etc/osmocom/mobile.cfg` + `virtphy -s /tmp/osmocom_l2`),
so T-A only watches receipts — no manual MM bring-up needed:

```bash
podman exec -it mvno-2g-ms /bin/bash
tail -f /root/.osmocom/bb/sms.txt          # MS1 auto-attached; receipts stream here
```
**EXPECT** — sms.txt exists and streams `[SMS from …]` lines as S3/S6a/6c send.
Leave this terminal attached for the whole demo (S6a/6c receipts). Steps
S4+ run on **T-B**.

**FALLBACK** — stack gates: `./scripts/preflight.sh` auto-verifies the host;
2G details: `docs/TESTING_REFERENCE.md` §Prerequisites & Flow A.

---

## S3 — 2G Receipt Sanity  ·  ~30 s

**PURPOSE** — confirm an SMS actually lands on the 2G MS before the four-path
SMS demo depends on it. This is the rawest possible messaging path
(2G→2G native).

> **FLOW**: `MO 15557778888 (2G-MS2) → SMPP SUBMIT_SM → OSMO-SMSC
> (mvno-osmosmsc @10.89.0.49:2775) → 2G radio (mvno-2g-core) → MT 15554443322
> (2G-MS1 → T-A sms.txt)` — no 5G, no bridge.

**COMMANDS** (T-B; T-A still attached)

```bash
python3 scripts/testing/send_raw_smpp.py 15557778888 15554443322 "Hello 2G sanity"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -3
```
**EXPECT** — `SMPP BIND_TRANSCEIVER Successful` + `SUBMIT_SM accepted
(ESME_ROK)`; on T-A, `[SMS from +15557778888]` / `Hello 2G sanity` appears in
`sms.txt`.

**FALLBACK** — path mechanics: `docs/TESTING_REFERENCE.md` Flow A; scripted
SMPP variant: S7.

---

## S4 — Real Call: baresip → RTPEngine → Vosk  ·  ~4 min

**PURPOSE** — the heart of the demo: a **real `baresip` voice call** (containerized
`mvno-baresip:1.1.0` rig, **compose-managed**), auto-answered, media anchored by
RTPEngine which records a pcap per call; then the `live_tap.sh` zero-Python
extraction and the Vosk transcript.

> **FLOW (this is the call path, live)**:
> ```
> CALLER (baresip-tx @10.89.0.61 — YOUR MIC when Pulse is up)
>   │ SIP INVITE 407→digest→100→180→200  [Kamailio mvno-kamailio @10.89.0.23:5060]
>   │  ├─ INTERCEPT REST callout → mvno-api:8080 (allow)
>   │  └─ rtpengine_manage → RTPEngine @10.89.0.48 (UDP 10000-20000)
>   ▼
> CALLEE (baresip-rx @10.89.0.60 — YOUR MIC too when Pulse is up; aufile scam
>         phrase only as the headless fallback)   [Issue 8.47: full-duplex live]
>   └─ every RTP packet → RTPEngine pcap → state/spool/pcaps/ → live_tap → Vosk
> ```

> **The rig**: `demo_call.sh` does NOT build/run containers anymore — `baresip-tx`
> and `baresip-rx` are **compose services** in `docker-compose.yml` (image
> `mvno-baresip:1.1.0`, libre v4.9.0 + baresip v4.10.0, stdio + aufile + pulse +
> g711 modules; `make up` brings them up, `make clean` removes them). The script
> only writes their `/cfg` configs into `state/baresip/{tx,rx}` and calls
> `podman compose up -d baresip-rx baresip-tx` to apply them. Caller
> `15553332211` (tx), callee `15559998888` (rx, auto-answer). **Both legs are
> YOUR LIVE MIC** when the host Pulse socket exists — full-duplex (Issue 8.47
> recipe): the caller leg is live mic → phone/rig, the callee leg is live mic →
> the other direction, with the remote leg played on your laptop speakers.
> `demo_call.sh dial` then prompts **"SPEAK NOW"** for ~10 s and Vosk transcribes
> your voice on both legs. No Pulse socket → the callee falls back to the aufile
> scam phrase and the caller to a canned tone (deterministic guard).
>
> **Audible go-cue**: the moment the speaking window opens (and the instant
> `mic_record.sh` starts capturing), a short two-tone **pep sound** plays over
> the host speakers — that is the "the call is live, start talking now" cue
> (`play_go_beep` in `scripts/lib/common.sh`; `paplay` → `aplay` → terminal
> BEL fallback; `MVNO_NO_BEEP=1` to mute for headless runs). Needs `ffmpeg` +
> `paplay`/`aplay` at call time — all of them are `preflight.sh` DEMO_TOOLS
> (S1), and a box without Pulse still degrades to the BEL, never a hard fail.
>
> **Live side-tone (hear yourself)**: with a real mic + Pulse, the SPEAK NOW
> window also starts a host-side `pactl` `module-loopback` (`side_tone_on` in
> `scripts/lib/common.sh`) — your own voice is routed back to the speakers in
> real time while you speak, like a phone earpiece. This is a **host-only
> monitor**: the recorded call path (baresip-tx → RTP → RTPEngine → pcap/WAV)
> is untouched, so the evidence stays honest. `MVNO_NO_SIDETONE=1` disables it,
> and it is never active in headless/tone-caller runs. Caveat: mic → speakers
> → mic acoustic feedback can howl in a loud room — the loopback lives only for
> the ~12 s window and is removed immediately after.
>
> **Sound / mic gain** (why it sounds "telephone-grade"): the relay uses **PCMU
> (G.711u, 8 kHz)** — telephony bandwidth by design; do not expect hi-fi. If a
> recorded leg is too quiet or noisy, set the mic level first
> (`pactl set-source-volume @DEFAULT_SOURCE@ 100%`), confirm with
> `mic_probe.sh` (mean ≈ −35..−20 dB), then re-run. Quick listen:
> `aplay "$(scripts/testing/newest.sh 'state/spool/archived/*.wav')"`. The
> **side-tone above** is the live "your mic works" proof; `mic_verify.sh`
> (graduation, S14) is the hard non-empty-transcript proof.
>
> **Phrase** (realistic, ASR-vetted): *"Your bank account has been blocked,
> please confirm your details now"* — Vosk hears it almost verbatim, so the
> `account`/`blocked`/`confirm` keyword anchors always survive. Customize with
> `SCAM_PHRASE="..." bash scripts/testing/demo_call.sh setup` (see `demo_call.sh`).

**COMMANDS** (T-B)

```bash
bash scripts/testing/demo_call.sh setup   # writes /cfg configs + both UAs register (~15 s)
bash scripts/testing/demo_call.sh dial    # real call; callee streams the phrase; SPEAK NOW for ~12 s
```
> **Preflight for S4** (skip if S1 preflight passed): verify UFW allows the RTP
> media range (`sudo ufw allow 5060/udp && sudo ufw allow 10000:20000/udp` on
> Ubuntu — else the phone leg rings with no audio) and that the Pulse socket
> exists (`test -S "$XDG_RUNTIME_DIR/pulse/native"` — needed for the live-mic
> legs; `demo_call.sh setup` exports `PULSE_SOCK`/`PULSE_DIR`/`PULSE_COOKIE`
> from your runtime dir automatically).
**EXPECT** — `setup` prints `rx registrations (expect >= 2)`/`tx registrations (expect >= 2)`
and the phrase; `dial` prints
`CALL_OUTGOING → CALL_RINGING → CALL_ANSWERED → CALL_ESTABLISHED →
CALL_RTPESTAB → CALL_CLOSED`, then `rx answers (expect 1): 1` and the fresh pcap.

Confirm the call answered and media flowed (**watch the hops live**):

```bash
podman logs baresip-rx | grep -c "200 Answering"    # expect 1
podman logs mvno-kamailio --since 3m 2>&1 | grep -iE "INVITE|ACK|BYE|INTERCEPT" | tail -6
NEW=$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')
echo "fresh pcap: $NEW"
curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_packets_total' \
  | jq -r '.data.result[0].value[1]'
```

Want to **inspect the capture in the Wireshark GUI** (not just the CLI tail)?
The cockpit's `--wireshark` flag launches it live as a **detached** capture
(spans `lo` + LAN via `-i any`; it is *not* a tmux pane); post-hoc, open the fresh
pcap above directly:

```bash
wireshark -r "$NEW" -d udp.port==10000-20000,rtp   # GUI decode of the RTP relay
```
**EXPECT** — `200 Answering` = 1; Kamailio shows the INVITE/ACK/BYE dialog plus
the `INTERCEPT QUERY: caller=15553332211 callee=15559998888` callout; `NEW` is a
pcap newer than S4 started; the RTPEngine counter is present.

> **Why the pcap "has no RTP" with `tshark -Y rtp`** — RTPEngine records pcaps on
> its **relay ports UDP 10000-20000**, which Wireshark does not auto-decode as
> RTP, so `-Y rtp` matches 0 and frames show as raw `data` (172-byte G.711).
> Force-decode to see the ~700+ RTP packets:
> ```bash
> tshark -r "$NEW" -d udp.port==30000,rtp -Y rtp 2>/dev/null | wc -l
> ```
> The `live_tap.sh` pipeline reads `data.data` (protocol-agnostic), so it is
> unaffected by this decode quirk.

**FALLBACK** — quieter room / no mic: `demo_call.sh` falls back to a canned
`ausine` tone caller; the callee scam leg still transcribes. Rig internals +
baresip ctrl-socket framing: `docs/TESTING_REFERENCE.md` §Raw mechanics &
Flow E.

---

## S5 — Extract → Vosk Transcript → BLOCK verdict  ·  ~2 min

**PURPOSE** — turn the recorded call into an audible/readable transcript (T-G
playback, T-C live), classify it via the AI filter, and show the **blocked**
verdict — first the **deterministic** rule, then the live record.

**COMMANDS** (T-B) — extract the newest recorded call:

```bash
NEW=$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')
bash scripts/testing/live_tap.sh --once "$NEW"
sleep 3
legs=$(scripts/testing/newest.sh "state/spool/${NEW##*/%.pcap}"* 2>/dev/null \
        || printf '%s\n' state/spool/"${NEW##*/%.pcap}"*)
ls -1 state/spool/"${NEW##*/}"*.wav 2>/dev/null
```

**EXPECT** — `WAV extracted: state/spool/<pcap-stem>-<srcip>.wav` per leg
(e.g. `…-10.89.0.60.wav` callee, `…-10.89.0.61.wav` caller). The naming is
**`<pcap-stem>-<src-ip>[.wav]`** — not a fixed `live-caller.wav`.

**PLAY THE CALLEE LEG** (T-G optional): hear what Vosk will read —

```bash
callee=$(scripts/testing/newest.sh 'state/spool/*10.89.0.60.wav')
ffprobe -v error -show_entries format=duration -of csv=p=0 "$callee"  # >= 3 s
aplay "$callee"                                                        # hear the scam phrase
```

**VOSK TRANSCRIPT** (T-B) — wait for the container-side Vosk service to
transcribe the dropped WAVs, then read them:

```bash
sleep 12                                 # Vosk watcher poll ~3 s
callee_txt="${callee%.wav}.txt"
echo "CALLEE: $(cat "$callee_txt" 2>/dev/null)"
podman logs mvno-api --since 2m 2>&1 | grep "AI transcript verdict" | tail -4
```

**EXPECT** — the callee leg transcribes the **bank-phishing phrase** (the canned
script; near-verbatim for this phrase, e.g.
`"your bank account has been blocked please confirm your detail now"`). If you
spoke the caller leg (S4 SPEAK NOW), that transcript is YOUR voice. The caller
tone leg is usually empty.

> **T-C optional live view** —
> ```bash
> watch -n2 'podman logs --since 5m mvno-api 2>&1 | grep "AI transcript verdict" | tail -3'
> ```

**BLOCK VERDICT — DETERMINISTIC proof (T-B)**: the ai-filter's TRANSCRIPT rule
blocks on any of `won prize claim free urgent account blocked confirm`. Call it
directly to prove the rule itself is correct (this always works, independent of
Vosk):

```bash
curl -s -X POST http://localhost:8008/ -H "Content-Type: application/json" \
  -d '{"event_type":"TRANSCRIPT","transcript":"your bank account has been blocked please confirm your detail now"}'
# -> {"allow": false, "reason": "Spam (phishing phrase detected)"}
```

**BLOCK VERDICT — assisted by the recorded phrase (T-B)**: seal the live record
in as the archive and confirm the counter:

```bash
before=$(curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total' \
  | jq -r '.data.result[0].value[1]'); echo "blocked BEFORE=$before"
cp "$callee" "state/spool/demo-scam-$(date +%s).wav"      # re-seed for the AI filter
sleep 12
after=$(curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total' \
  | jq -r '.data.result[0].value[1]'); echo "blocked AFTER=$after"
```

**EXPECT / CAVEAT — read this honestly**: the block is **deterministic at the
rule layer** (the direct TRANSCRIPT call above always returns `allow:false`) but
the **live re-arch is WER-dependent**: if Vosk mangles the phrase so no keyword
survives (e.g. `"you have one a prime target"` → contains no keyword →
`allow:true`), the counter does not move. This is inherent to ASR, not a fault.
**The default phrase was chosen to make this work**: its anchors
`account` / `blocked` / `confirm` transcribe near-verbatim (verified live
2026-08-08). **If you need the counter to move on the spot, run the
deterministic proof (it cannot fail) and say so.** To make the live arch
reliably block, speak the phrase slowly — `account` and `blocked` are the most
ASR-stable anchors.

**FALLBACK** — fixtures (no mic, no call): `docs/evidence/fixtures/archived/
live-385288b…-10.89.0.60-0.{wav,txt}` (certified scam transcript) + Flow M in
`docs/TESTING_REFERENCE.md`; deterministic SIP-side block: Flow K.

---

## S6 — The Four SMS Paths (A: 2G→2G, B: 2G→5G, C: 5G→2G, D: 5G→5G)  ·  ~5 min

**PURPOSE** — every messaging path the core implements, raw and observable.
Keep T-A attached (S6a/6c receipts land in its `sms.txt`). Each block below
states its **FLOW** first (MO → nodes → MT, with container + port), then sends
**a message of YOUR choice** — replace the quoted text with anything.

> **T-C live hop trace** — while S6 runs, watch every node light up in one
> terminal:
> ```bash
> watch -n2 'podman logs --since 30s mvno-ip-sm-gw 2>&1 | grep -E "POLL|RELAY|DELIVERED|SMPP" | tail -2; \
>   podman logs --since 30s mvno-kamailio 2>&1 | grep -E "SMS INTERCEPT|MESSAGE" | tail -2'
> ```

**S6a — 2G→2G** (raw binary SMPP over `nc`, port 2775)

> **FLOW**: `MO 15557778888 (2G-MS2/ms2 @10.89.0.52) → OSMO-SMSC (mvno-osmosmsc
> @10.89.0.49:2775, ESME route) → 2G radio (mvno-2g-core @10.89.0.50) → MT
> 15554443322 (2G-MS1/ms1 @10.89.0.51 → T-A sms.txt)`. Bridge/SMPP counters
> stay flat (native 2G, no 5G, no IP-SM-GW).

```bash
python3 scripts/testing/send_raw_smpp.py 15557778888 15554443322 "Hello raw 2G2G"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```
**EXPECT** — `SMPP BIND_TRANSCEIVER Successful` + `SUBMIT_SM accepted
(ESME_ROK)`; MS1 prints `[SMS from +15557778888]` / `Hello raw 2G2G`. Bridge
counters stay flat (not involved).

**S6b — 2G→5G** (row into the bridge's polled queue)

> **FLOW**: `MO 15554443322 (2G-MS1) → smsc.db row (state/hlr/smsc.db) →
> IP-SM-GW bridge (mvno-ip-sm-gw @10.89.0.53, polls smsc.db) → SIP MESSAGE →
> KAMAILIO (mvno-kamailio @10.89.0.23:5060, INTERCEPT_SMS callout to
> mvno-api:8080 → ai-filter:8008) → MT 15559998888 (baresip-rx @10.89.0.60,
> prints the body)`.

```bash
python3 scripts/testing/inject_smsc_row.py 15554443322 15559998888 "Hello raw 2G5G"
sleep 8
podman logs mvno-ip-sm-gw --since 2m 2>&1 | grep -E "POLL|DELIVERED" | tail -2
podman logs baresip-rx 2>&1 | grep "Hello raw 2G5G"    # MESSAGE body seen
```
**EXPECT** — bridge `[POLL] row_id=NN …` → `[DELIVERED] row_id=NN marked sent`;
Kamailio relays; baresip-rx prints the body. Clean up after so the gates stay
unpolluted:
```bash
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"
```

**S6c — 5G→2G** (digest-auth SIP MESSAGE via Kamailio 5060)

> **FLOW**: `MO 15553332211 (baresip-tx @10.89.0.61 — or any digest UA) → SIP
> MESSAGE → KAMAILIO 5060 (digest auth `testpass`; INTERCEPT_SMS → ai-filter) →
> IP-SM-GW bridge (mvno-ip-sm-gw [RELAY] 5G→2G) → SMPP SUBMIT_SM → OSMO-SMSC
> @2775 → 2G radio → MT 15554443322 (2G-MS1 → T-A sms.txt)`.

```bash
python3 scripts/testing/send_digest_sms.py 15553332211 15554443322 "Hello raw 5G2G"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```
**EXPECT** — `SIP/2.0 200 OK`; bridge `[RELAY] 5G->2G …` + `[SMPP] BIND_TRANSCEIVER
OK` + `[SMPP] SUBMIT_SM OK`; MS1 prints `[SMS from +15553332211]` /
`Hello raw 5G2G`. (MS2 trap: an SMS to `15557778888` is accepted but never
receipted — the 2G container serves only MS1; always use `15554443322`.)

**S6d — 5G→5G** (digest-auth SIP MESSAGE to the registered IMS number)

> **FLOW**: `MO 15553332211 (baresip-tx @10.89.0.61) → SIP MESSAGE → KAMAILIO
> 5060 (digest auth; INTERCEPT_SMS → ai-filter) → lookup("location") → MT
> 15559998888 (baresip-rx @10.89.0.60)`. Pure IMS-to-IMS — no bridge/SMPP
> (those counters stay flat).

```bash
python3 scripts/testing/send_digest_sms.py 15553332211 15559998888 "Hello raw 5G5G"
sleep 8
podman logs baresip-rx 2>&1 | grep "Hello raw 5G5G"    # body received
```
**EXPECT** — `SIP/2.0 200 OK`; baresip-rx prints the body — pure IMS-to-IMS SMS,
no bridge/SMPP (those counters stay flat).

**FALLBACK** — per-path terminal setups: `docs/TESTING_REFERENCE.md` Flows A–D;
raw PDU/digest mechanics: §Raw mechanics; scripted SMPP variant: S7.

---

## S7 — SMPP (scripted SUBMIT_SM + stored row)  ·  ~1 min

**PURPOSE** — the same SMPP 3.4 channel via the harness, ending with the SMS
row provably stored in the SMSC DB (terminal evidence).

> **FLOW**: `MO 15551234567 (ESME: send_smpp_sms.py, BIND_TRANSCEIVER) →
> OSMO-SMSC @10.89.0.49:2775 (esme mvno-api-route) → smsc.db row
> (state/hlr/smsc.db — stored for the MT leg) → REST intercept verdict
> (mvno-api:8080 → ai-filter:8008)`.

**COMMANDS** (T-B)

```bash
python3 scripts/testing/send_smpp_sms.py    # bind + SUBMIT_SM 15551234567 -> 15557654321
sqlite3 -header -column state/hlr/smsc.db \
  "SELECT id, src_addr, dest_addr, hex(substr(user_data,1,20)) AS content_gsm7, created, sent \
   FROM SMS ORDER BY id DESC LIMIT 5;"
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"   # drain (gate hygiene)
```
**EXPECT** — `BIND_TRANSCEIVER Successful` / `SUBMIT_SM Delivered` /
`Status=0x00000000` (ESME_ROK); the dump shows the row with
`src_addr=15551234567, dest_addr=15557654321` and a non-NULL `content_gsm7`.
> **Why `user_data`, not `text`**: OsmoSMSC stores the payload GSM-7-packed in
> `user_data` (BLOB); the `text` column stays empty. Decode it the same way
> `ip_sm_gw.gsm7_decode` does (see `live_demo.sh` nonce check) — e.g.
> `python3 -c "from ip_sm_gw import gsm7_decode; print(gsm7_decode(bytes.fromhex('<hex>')))"`.

**FALLBACK** — PDU anatomy + injector internals: `docs/TESTING_REFERENCE.md`
Flows B & §Injectors; automated: `live_demo.sh` items 10/10b.

---

## S8 — REST API + smsc DB Dump  ·  ~1 min

**PURPOSE** — the gateway interception API: clean content allowed, the E2E spam
marker blocked; then the terminal evidence dump of the SMSC store.

> **FLOW**: `curl (any HTTP client) → POST /api/v1/intercept/sms
> (mvno-api @10.89.0.46:8080, X-API-Key) → ai-filter @10.89.0.44:8008
> (classify) → {allow, reason} verdict` — the same verdict path Kamailio and
> the bridge use per-message.

**COMMANDS** (T-B)

```bash
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender":"15551234567","recipient":"15557654321","content":"Hello MVNO 5G"}'
# -> {"allow":true,"reason":"Clean content"}
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender":"15551234567","recipient":"15557654321","content":"E2E-BLOCK REST test"}'
# -> {"allow":false,"reason":"Spam (E2E deterministic block)"}
sqlite3 -header -column state/hlr/smsc.db \
  "SELECT src_addr, dest_addr, hex(substr(user_data,1,20)) AS content_gsm7, sent \
   FROM SMS ORDER BY id DESC LIMIT 5;"
```
**EXPECT** — two verdicts (allow true/false). The smsc.db dump shows stored
SMS rows only if S3/S6/S7 ran and were NOT drained (S7 ends with a
`DELETE WHERE sent IS NULL` drain for gate hygiene — run S8's dump before that
drain, or re-send a message, to see rows; content is GSM-7-packed in
`user_data`, see S7). The REST intercept itself does NOT write smsc.db — it
evaluates the same verdict path Kamailio/the bridge use; the DB rows are
terminal evidence of the *messaging* flows.

**FALLBACK** — API schema: `docs/TESTING_REFERENCE.md` Flow I + INTEGRATION_CONTRACT.

---

## S9 — PromQL / Grafana  ·  ~1 min

**PURPOSE** — telemetry: the interception counters live in VictoriaMetrics and
the NOC dashboard renders.

**COMMANDS** (T-B)

```bash
for q in mvno_call_requests_total mvno_vosk_classified_total \
         mvno_vosk_blocked_total mvno_sms_blocked_total; do
  printf '%-28s ' "$q"
  curl -s "http://localhost:8428/api/v1/query?query=$q" \
    | jq -r '.data.result[0].value[1]'
done
curl -s -o /dev/null -w "grafana login HTTP %{http_code}\n" http://localhost:3000/login
```
**EXPECT** — every counter returns a number (`>= 1` for call/classified after
S4–S5); Grafana login HTTP 200.

**FALLBACK** — dashboard JSON: `docs/evidence/grafana-mvno-unified-noc.json`;
details: `docs/TESTING_REFERENCE.md` Flow J.

---

## S10 — Validation Gates  ·  ~15 min

**PURPOSE** — the automated proof: the e2e SMS matrix (5 cells / 8 ok) then the
full 13-item demo, both exiting 0, both teed to `docs/evidence/` logs.

> **Automated equivalent**: `make gate` (`scripts/testing/gate.sh` = 5G
> preflight + sms_matrix, exit-only, no mic) is the deterministic oracle — run
> it for CI-style certification. S10 runs the two scripts directly so the
> narrated demo shows each layer's evidence live.

**COMMANDS** (T-B)

```bash
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"   # drain leftover rows
./scripts/testing/sms_matrix.sh ; echo "e2e exit=$?"             # ALL CELLS PASS, exit=0
./scripts/testing/live_demo.sh ; echo "demo exit=$?"           # ALL 13 PASSED, exit=0
podman rm -f baresip-rx baresip-tx    # demo cleanup (baresip is demo-only)
```
**EXPECT** — `SMS MATRIX: ALL CELLS PASS (8 ok)` / `exit=0`; demo
`ALL 13 DEMO ITEMS PASSED` / `exit=0`; fresh logs
`docs/evidence/e2e-run-<date>.log` and `docs/evidence/demo-run-<date>.log`
(each run appends its day's file).

> **Note on `live_demo.sh` item 9b**: the fresh-transcript `grep` for scam
> keywords is itself WER-dependent (see S5). Its EXPECT is written
> permissively for that cell; the **deterministic** transcript rule proof is
> S5's direct `curl`. If 9b flakes on a live re-arch, re-run it or cite the S5
> direct proof.

**FALLBACK** — gate internals: `docs/TESTING_REFERENCE.md` Flows L & N;
failure-path checks: Flow O.

---

## S11 — One-Shot Demo Cockpit (tmux) · ~1 min

**PURPOSE** — S4–S9 as a single tmux cockpit: the real call with your live mic,
**mid-call transcription** (the `live_tap.sh` daemon feeding Vosk while the call
is still up), **live capture** of the RTP/SIP traffic, plus log/metrics/receipt
watches — all in one session, with an auto-recovering 5G preflight.

```bash
bash scripts/demo/demo_live.sh          # preflight -> tmux session mvno-live (3 windows x 4 panes)
bash scripts/demo/demo_live.sh --wireshark  # + DETACHED Wireshark GUI live capture
#                                        #   (NOT a pane; Qt platform + XAUTHORITY + lo
#                                        #   capture-perm handled by the launcher; GUI
#                                        #   stderr -> state/logs/wireshark-gui.log)
bash scripts/demo/demo_live.sh --windowed   # pop the cockpit up as a VISIBLE
#                                        #   desktop terminal window (konsole /
#                                        #   kitty / alacritty / … auto-picked;
#                                        #   needs a display; headless prints
#                                        #   the tmux-attach hint instead)
# ... run the call from P0 (SPEAK NOW ~12 s), watch the daemon + capture ...
bash scripts/demo/demo_live.sh --down   # teardown (idempotent; evidence kept)
```

> **See it on your screen**: the cockpit session is built detached (`tmux
> new-session -d`), so by itself it never opens a window. Run it from a
> terminal and it auto-attaches (`tmux attach -t mvno-live`), or use
> `--windowed` to pop up a desktop terminal window that attaches — the session
> stays deterministic either way; only the VIEW is brought to the screen.

**WINDOW MAP** (session `mvno-live` — **never more than 4 terminals on screen at
once**; switch with `Ctrl-b n` / `Ctrl-b p`, or
`tmux select-window -t mvno-live:call|monitors|sms`):

**Window `call`** — the voice call + live transcription:

| Pane | Live content | Equiv |
|---|---|---|
| **P0** (top-left) | `demo_call.sh setup && dial` — **SPEAK NOW = your mic** (+ side-tone) | S4 |
| **P1** (top-right) | `live_tap.sh daemon` — pcap → 16 kHz WAV → Vosk chunks mid-call | S4/S5 |
| **P2** (bottom-left) | live capture — RTP `10000-20000` + SIP `5060` on host loopback | S4 |
| **P4** (bottom-right) | **Vosk LIVE readout** — verdict logs **+ the raw recognized text** (`live-*.txt` tail) | S4/S5 |

**Window `monitors`** — network + health:

| Pane | Live content | Equiv |
|---|---|---|
| **P3** (top-left) | `podman logs -f mvno-kamailio` — REGISTER/INVITE/INTERCEPT | S4 |
| **P5** (top-right) | metrics — `mvno_vosk_blocked_total` + rtpengine counters | S9 |
| **P7** (bottom-left) | evidence — newest `state/spool` WAVs + archived transcripts | S5 |
| **watchdog** (bottom-right) | `state/logs/watchdog.log` tail — 24/7 functional health | S13 |

**Window `sms`** — SMS MO/MT terminals (2G + 5G):

| Pane | Live content | Equiv |
|---|---|---|
| **S1** (top-left) | **MO (send)** tools — `send_rest_sms.sh`, `send_smpp_sms.py`, `sms_matrix.sh` | S6–S8 |
| **S2** (top-right) | counters — bridge `mvno_bridge_sms_*` + `smsc.db` pending/total | S6/S7 |
| **S3** (bottom-left) | **MT 2G** — `sms.txt` tail on `mvno-2g-ms` (real handset receipt) | S6a/6c |
| **S4** (bottom-right) | **MT 5G/IMS** — `ims_rx` receiver logs (auto-follows sms_matrix receivers) | S6c/6d |

> Pane **positions** are fixed by the 2×2 grid above; tmux _numeric_ pane indexes
> are resolved at runtime from `${TMPDIR}/mvno-cockpit-panes.map` (written by
> `demo_live.sh`) — tmux renumbers indexes by layout, not creation order, so the
> map is the version-proof source of truth (cockpit-proof reads it).

**What the preflight does before the panes open** (all audited against
`docs/ISSUES.md`):

- **Refuses to collide** with a running `live_demo.sh` (re-entrancy lock) and
  refuses a second cockpit while one exists.
- **Spool 777** guarantee (mirror of `make init-db`) so the daemon/rtpengine/
  mvno-api three-uid write path works from a cold start.
- **Mic probe is SOFT here** — a no-mic run warns and the caller falls back to
  the canned tone leg; the callee/scam block still works (S5 honesty rule:
  the block verdict keys off the callee/synthetic leg only).
- **5G user plane auto-recovery** — `preflight_5g.sh --auto-recover` runs the
  documented 5.8/5.9/7.x ladder (stage 1: `podman restart mvno-ueransim-ue-1`;
  stage 2: atomic UERANSIM trio recreate — never a single UERANSIM container,
  Issue 7.4) before the call. This is the **demo path only**: `make gate`
  keeps `--no-recover` and stays the deterministic oracle.
- **Clean slate** (Issue 8.37): removes `baresip-rx/tx` and deregisters only
  the cockpit's own rig AoRs (`15559998888` baresip-rx/preflight UAS,
  `15553332211` baresip-tx). The bridge-owned 2G registrations
  (`15554443322` / `15557778888`, held by `mvno-ip-sm-gw` for the 5G→2G relay)
  are deliberately **not** deregistered — removing them breaks the 5G→2G
  route until the bridge's 900 s refresh (a real gate regression caught live).

**Packet-analysis panes**: rootless podman publishes the RTP relay on host
loopback, so capture targets `lo` (Issue 8.20 — host has no route to the bridge
IPs) with a forced RTP decode. The plan's `udp.portrange` decode field is
**not** valid in tshark 4.x; the working form (verified on this host) is
`-d udp.port==10000-20000,rtp` (range as value). Two live views exist:

- **P2 — CLI (default, headless-safe)**: live `tshark` tail of the loopback
  capture; if live capture lacks dumpcap permissions it falls back to tailing
  the newest relay pcap with the same decode.
- **Wireshark GUI — DETACHED, not a pane**: `demo_live.sh --wireshark` launches
  `wireshark -k -i any` (multi-interface: loopback + LAN for the mobile phone;
  RTP decode on UDP 10000-20000) as a **background process** — a GUI cannot
  live reliably inside a tmux pane. The launcher handles the classic
  no-window causes explicitly: the Qt platform plugin under Wayland
  (`QT_QPA_PLATFORM=wayland`, xcb fallback for XWayland), an empty
  `XAUTHORITY` (`~/.Xauthority` default), and a `dumpcap` lo-capture-probe
  with the exact `setcap` remediation. GUI errors land in
  `state/logs/wireshark-gui.log`. Deterministic cockpit/proof runs never use
  it; headless runs print the post-hoc one-liner instead:

```bash
# open the newest saved relay pcap in the Wireshark GUI (post-hoc, any time):
wireshark -r "$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')" \
  -d udp.port==10000-20000,rtp
```

**Teardown** keeps the evidence (pcaps, `live-*.wav`, archived transcripts),
removes the rigs, deregisters the AoRs, and drains `smsc.db` `sent IS NULL`
rows so `sms_matrix.sh` / `live_demo.sh` stay green afterward.

---

## S12 — Adding a Subscriber · ~1 min

**PURPOSE** — provision a brand-new user (2G + 5G) with a single MSISDN;
IMSI and the 5G crypto keys are derived automatically.

```bash
bash scripts/add-subscriber.sh 15551234999            # full 2G+5G user (balance 100)
bash scripts/add-subscriber.sh 15551234998 --2g-only # 2G/3G only (no keys)
bash scripts/add-subscriber.sh 15551234997 --balance 250  # opening credit 250
#                                                        (Kamailio auth_db; the
#                                                         SIP 403-on-zero-balance
#                                                         contract reads this)
```

**EXPECT** — the script writes **every store** the stack reads:
OsmoHLR VTY (2G), `state/hlr/hlr.db` mirror, the **Kamailio sqlite `auth_db`**
(the store `kamailio.cfg` digest-authenticates — without it the new user
cannot SIP-auth; the `--balance` opening credit lands here and drives the
SIP 403-on-zero-balance contract), the Kamailio MongoDB parallel store, and the Open5GS MongoDB
5G SA doc (top-level `ambr`/`msisdn`/`slice` + `security` K/OP — the
`f8e367b` true-cold REGISTER requirement). It refuses to overwrite an MSISDN/
IMSI already present, and (full mode) generates
`configs/ueransim/ue-<N>.yaml` with the auto K/OP plus the compose service
snippet for an optional real attach (`podman compose up -d ueransim-ue-<N>`).

> **Crypto truth** (why 5G keys are generated and 2G keys are not): a 5G SA
> REGISTER is impossible without K/OP/AMF on **both** the core and the UE;
> 2G/3G authentication is IMSI-based, so a 2G user needs only IMSI+MSISDN.

## S13 — Stack Watchdog & Functional Health · continuous

**PURPOSE** — close the "silent-but-Up" holes that `restart: unless-stopped`
cannot catch (it only fires on process exit): a UE whose PDU session dropped
or a bridge whose 5G→2G registrations died can stay "Up" while the function
is dead. The watchdog detects those continuously and recovers automatically.

```bash
make watchdog-install   # systemd --user service, 30s cadence (24/7)
make watchdog-once      # one check (+recovery if needed); exit 0 healthy
make watchdog-log       # state/logs/watchdog.log
make watchdog-uninstall
```

**What it watches** (all live, no restart needed):

| Signal | Healthy iff | Failure recovery |
|---|---|---|
| UE fleet | `ran_ue == 3` (AMF gauge) **and** every UE has a live `uesimtun0` | `preflight_5g.sh --auto-recover` (bounded ladder: ue-1 restart → atomic trio) |
| Bridge 5G→2G leg | `15554443322` + `15557778888` present in Kamailio `usrloc` | `podman restart mvno-ip-sm-gw` (re-REGISTERs both AoRs at boot) |

**Never fights a run** — recovery is skipped while `live_demo.sh`,
`sms_matrix.sh`, `gate.sh`, or the `mvno-live` cockpit is in flight (lock
files + tmux session + pgrep), and the **gate oracle is untouched** (recovery
is the opt-in `--auto-recover` ladder; `make gate` still strict).

**Compose healthchecks** (visibility; the watchdog is the recovery actor):
`mvno-ip-sm-gw` probes its `/health` endpoint (live registration state —
HTTP 200 ok / 503 degraded), and `ueransim-ue-1/2/3` probe `uesimtun0`
presence. `podman ps` shows `(healthy)`/`(unhealthy)` accordingly.

> **24/7 across logout**: `loginctl enable-linger $(USER)` lets the systemd
> --user unit keep running without a login session.

## S14 — Evidence Squares (`make proof`) · repeatable

**PURPOSE** — turn "the cockpit works" / "add-subscriber works" / "the
watchdog recovers" from code-verified claims into **captured, repeatable
run-evidence** (same spirit as `sms_matrix.sh`). One command, three
self-asserting proofs, each tee'd to `docs/evidence/`:

```bash
make proof
# → cockpit-proof → subscriber-proof → watchdog-self-test (stops at first red)
```

| Proof | Evidence log | Must contain to be green |
|---|---|---|
| `cockpit-proof` (deterministic, tone caller) | `demo-cockpit-<date>.log` | 12 panes up (3 windows `call`/`monitors`/`sms` × 4, ≤4 per screen); live_tap daemon polling; a **fresh** pcap + `live-*.wav` chunk + `archived/*.txt` within the REALTIME_AUDIO budget; `tshark -r` decodes **>0 RTP frames** on the 30000 range (Issue 4.2); teardown clean |
| `cockpit-proof --live-mic` (opt-in) | same log | genuine fresh mic capture; **non-empty transcript = real-voice headline proven**. Empty transcript (quiet room / unmuted mic) does **NOT** fail — `silence_mark.sh` annotates it as `[caller/you · recorded Ns · SILENCE "···" N symbols]` and the run is PASS-with-note. The raw WAV + empty `.txt` remain the honest evidence. (`mic_verify.sh` — the graduation anti-theater gate — is **unchanged** and still hard-fails on silence.) |
| `subscriber-proof` | `demo-subscriber-<date>.log` | throwaway MSISDN provisioned via `add-subscriber.sh`; **all 5 stores** contain the row (osmo-hlr VTY, hlr.db, Kamailio sqlite auth_db, Kamailio Mongo, Open5GS Mongo); a **real SIP REGISTER 200 OK** for that MSISDN (the testpass/auth_db path SipClient uses); throwaway row cleaned up |
| `watchdog-self-test` (fault injection) | `watchdog-recovery-<date>.log` | bridge stopped → watchdog detects → 2-round restart recovery → `/health` 200 again |

> **Anti-theater contract**: these proofs are additive and opt-in. `make gate`
> / the 8-cell oracle is untouched; `mic_verify.sh` stays strict; the proofs
> only make "it works" *provable on demand* instead of asserted from memory.

---

## Partner-Repo Integration (read-only references)

The org repos **`sms-client`**, **`SipClient`**, and **`AI-Filteration-System`**
(https://github.com/AI-SpamFilter-PMN) are **not ours to modify** — we only prove
the same ESME / UA / filter behaviour **here, MVNO-natively**:

- **`sms-client` (Java ESME)** sends SMPP SUBMIT_SM to the SMSC. What S6a/S7
  demonstrate with `send_raw_smpp.py`/`send_smpp_sms.py` is exactly the PDU
  session that Java ESME issues — same SMSC, same ESME_ROK receipt.
- **`SipClient` (Java SIP UA)** dials/registers like `baresip-tx/rx` do in S4.
  The IMS call + SIP MESSAGE we show here (S6c/6d) is the same flow SipClient
  drives; our containerized rig keeps the state reproducible without rebuilding
  the Java client.
- **`AI-Filteration-System`** provides the model; here `ai-filter` (S5) runs the
  keyword layer the demo certifies. The partner repos have known config
  mismatches vs this stack (documented in `ONBOARDING.md`); we reference, do not
  edit.

Three of the four partner repos are currently 0-ahead/0-behind their remotes;
**`sms-client` is 3 commits behind** (`origin/main`, non-fast-forward — local
work not yet pushed by the partner team). We reference these repos read-only;
the MVNO-native equivalents (S6a/S7) prove the same ESME behaviour without
depending on the partner repo's state.

---

## Quick Gate Checklist (before calling it done)

> **First-run prerequisite** — on a fresh box run `make bootstrap` (≡ `make
> init-db` → `make up` → `make seed-mongo` → `make bootstrap-check`) once first;
> every gate below assumes the subscriber DBs and Open5GS Mongo are populated.
> `make gate` is the deterministic oracle (5G preflight + 8-cell SMS matrix);
> `make bootstrap-check` is the fast cold-start health gate; the two scripts
> below are the narrated equivalents.

```bash
bash scripts/check-glossary.sh                                    # exit 0 (docs lint)
make bootstrap-check                                            # exit 0 (8/8 cold-start gate)
make gate                                                       # exit 0 (8/8 oracle)
./scripts/testing/sms_matrix.sh >/dev/null && echo "E2E OK"     # exit 0
./scripts/testing/live_demo.sh >/dev/null && echo "DEMO OK"   # exit 0
```

---

## S15 — Test With a Real External SIP Client (mobile / laptop softphone) · optional

**PURPOSE** — prove the SIP/RTP path from a **real third-party RFC-3261
softphone** (phone app / Zoiper / MicroSIP / Linphone / Blink, or the teammate
`SipClient` repo's JavaFX UA) end-to-end against MVNO, including live media
through RTPEngine. This doubles as the integration test for the `SipClient`
teammate repo (drop-in: `docs/partner/SipClient-INTEGRATION.md`).

> Ports bind on `*` (verified live): `5060/udp` (SIP) and `10000-20000/udp`
> (RTP) are reachable from any host on the same LAN. Keep firewall UDP
> `5060` + `10000-20000` open.

**SETUP** (one provisioned number is enough — e.g. `15553332211`):

```bash
bash scripts/add-subscriber.sh 15553332211   # seed it if not already present
hostname -I | awk '{print $1}'               # LAN IP the phone should reach
```

On the softphone, add an account:
- **Server / Proxy**: `<this-host-IP>:5060` (UDP)
- **Username**: the MSISDN (`15553332211`) · **Password**: `testpass` · **Auth**: digest
- **Realm**: `localhost` · **Codec**: **PCMU only** (G.711u) — disable G.722/OPUS (no transcode, S4)
- REGISTER. **EXPECT**: `SIP 200 OK` (Kamailio `auth_db`; bad password → 401/403).

**CALL**: dial another registered number (cockpit callee `15559998888` when the
baresip rig is up, or a second softphone/SipClient). **EXPECT**: `200 OK`
answer, audio both ways via RTPEngine, a fresh pcap in `state/spool/pcaps/`,
and (S11 / S5) a live Vosk transcript.

**Verify**:
```bash
podman logs mvno-kamailio --since 5m | grep -E 'REGISTER|INVITE|INTERCEPT' | tail
podman logs baresip-rx | grep -c '200 Answering'            # if callee rig up
NEW=$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap'); echo "$NEW"
```
> Zero-balance / EIR-fraud / AI-block numbers answer with `SIP 403 Forbidden` —
> correct terminal behavior; treat 403 as final (no retry loop).

> **SMS from the same clients is supported too (2026-08-14)**: the bridge
> accepts RFC 3261 bracketless `To: sip:..@..` headers (Linphone/MizuDroid
> style, Issue 8.51), Kamailio normalizes `+`/`00`/`0`-prefixed `From:` before
> the OCS balance lookup (Issue 8.56 — Java SipClient intl format no longer
> 403s as "prepaid exhausted"), and RFC 3994 typing indicators are consumed
> silently instead of being relayed as fake SMS (Issue 8.52). Any client that
> sends `MESSAGE` with digest auth can reach the 2G leg; bare MSISDN or
> international `+20…` From both work.

> **Why this matters for integration**: MVNO exposes *standard* SIP (RFC 3261 +
> digest, PCMU relay), so any standards-based client registers and calls with
> **zero MVNO-side changes** — this is exactly the surface the `SipClient`
> teammate repo targets.

## S16 — Conference / Voicemail / Call-Screening (Asterisk media server) · optional

**PURPOSE** — prove carrier-grade 3GPP in-call handling, supplementary services,
and media server features behind Kamailio:
1. **3GPP Multi-Party Conferencing (RFC 4579 / TS 24.147)**: Native "Add Call" -> "Merge Calls" via `sip:conf-factory@192.168.100.93:5060`.
2. **Call Waiting & Call Hold (3GPP TS 24.615 / TS 24.610)**: Receive 2nd call while talking, put 1st leg on hold, swap between legs.
3. **Quick-Reply Rejections (3GPP TS 24.607)**: Decline with instant SMS ("In a meeting", "Busy", "Out of office").
4. **Voicemail Main & Pre-Recorded Greetings (8XXX)**: Custom greetings, busy announcements, and inbox recording.
5. **Call Screening IVR (8000)**: Interactive speech screening with DTMF accept/decline.

| Method / URI | 3GPP Feature | Behavior & Flow |
|---|---|---|
| `conf-factory` / `conference` | RFC 4579 Conference Factory | Linphone "Merge Calls" button transfers active calls into mixed ConfBridge |
| `7XXX` (e.g. `7001`) | ConfBridge Room (Direct) | Multi-party audio mixer with TX/RX volume amplification |
| `8XXX` (e.g. `8100`) | Voicemail Main (Mailbox XXX) | Check and record voicemail greetings and messages |
| `8000` | Call-Screening IVR | Caller states name -> Callee presses 1 to Accept, 2 to Decline, 3 to Voicemail |
| Quick SMS Reply | 3GPP In-Meeting Auto-Response | Sends SMS ("In a meeting, call back later") + terminates call with 486 Busy |

**3GPP In-Call Handling & Conference Demo (`call_waiting_conference_demo.py`)**:
```bash
python3 scripts/testing/call_waiting_conference_demo.py
# Runs 3 complete scenarios: 
#   1) Call Waiting + Put on Hold
#   2) Handset "Merge Calls" -> 3GPP RFC 4579 Conference Factory
#   3) Quick SMS Auto-Reply ("In a meeting") + SIP 486 Busy Decline
```

**Linphone Native 3-Way Conference Setup**:
1. In Android Linphone: *Settings -> Audio / Call -> Conference Factory URI* = `sip:conf-factory@192.168.100.93:5060`.
2. During an active call with `15559998888`, tap `+ (Add Call)` and dial `15553332211`.
3. Tap `Merge Calls` -> Linphone automatically sends SIP INVITE to `conf-factory`, bridging all 3 parties into a live mixed conference!

**Voicemail (S16b)** — dial `8100`, log in to mailbox `100` (password
`testpass`), record a greeting / leave a message:
```bash
podman exec baresip-tx python3 /cfg/baresip_dial.py --uri "sip:8100@10.89.0.23:5060" --timeout 25
podman exec mvno-asterisk asterisk -rx "core show channels"      # VoiceMailMain executing
podman exec mvno-asterisk ls /var/spool/asterisk/voicemail/default/100/   # recorded msgs
```
**EXPECT** — `VoiceMailMain` runs (log: `Executing [8100@mvno:2]
VoiceMailMain`), mailbox 100 exists, messages land under
`/var/spool/asterisk/voicemail/default/100/INBOX/`.

**Screening (S16c)** — the accept-leg really rings the rig:
```bash
podman exec baresip-tx python3 /cfg/baresip_dial.py --uri "sip:8000@10.89.0.23:5060" --timeout 35   # then press 1 / 2 / 3
podman logs --since 2m baresip-rx | grep 'Call established'     # accept-leg reached the rig
podman exec mvno-asterisk ls /tmp/screening-*.wav                # the recorded name
```
**EXPECT** — Record() saves the caller's name WAV; pressing **1** makes
Asterisk Dial the rig callee as registered UA `15550000001` and baresip-rx
logs `Call established: sip:15550000001@10.89.0.23`; **2** plays goodbye;
**3** routes to Voicemail(1000).

> **Why this matters**: a real conference/Voicemail/screening capability now
> exists without any custom media code — stock Asterisk apps behind the
> existing Kamailio gate. Any UA (phone, baresip rig, SipClient) dials the
> feature number and gets the service; the interception core still records
> and gates every call. See `docs/ARCHITECTURE_DECISIONS.md` §3 and
> `docs/ISSUES.md` 8.62.

---

## Appendix A — Address & Port Reference (authoritative bindings)

Every address this demo touches, what it is, and whether it is **static** or
**dynamic**. The container plan lives in `docker-compose.yml` (static pins,
Issue 8.19); host ports are published for rootless Podman/Docker on
`127.0.0.1`/`0.0.0.0` as shown. UE user-plane IPs are **dynamic** — always read
`uesimtun0` at runtime, never hardcode.

### A.1 — Host-published ports (this is what external tools/SIP/SMPP clients use)

| Host endpoint | Container → port | Service | Demo step |
|---|---|---|---|
| `127.0.0.1:5060/udp` | kamailio `:5060` | SIP registrar/proxy (digest auth) | S6c/6d (external clients: INTEGRATION_CONTRACT §1) |
| `127.0.0.1:2775` | osmo-smsc `:2775` | SMPP 3.4 SMSC (ESME bind/submit) | S3, S6a, S7 |
| `127.0.0.1:8080` | telecom-api `:8080` | REST intercept API + actuator | S2, S8 |
| `127.0.0.1:8008` | ai-filter `:8000` | AI classifier (mock, deterministic rules) | S2, S5 |
| `127.0.0.1:8428` | victoria-metrics `:8428` | PromQL / vmui | S2, S5, S9 |
| `127.0.0.1:8429` | vmagent `:8429` | scrape-agent self-metrics | S2 (optional) |
| `127.0.0.1:3000` | grafana `:3000` | NOC dashboards | S9 |
| `127.0.0.1:9999` | open5gs-webui `:3000` | 5G subscriber UI | — |
| `127.0.0.1:27017` | mongodb `:27017` | 5G core subscriber DB | — |
| `127.0.0.1:9900` | rtpengine `:9900` | RTPEngine Prometheus metrics | S9 (T8) |
| `127.0.0.1:10000-20000/udp` | rtpengine `:10000-20000` | RTP media relay range (G.711 PCMU) | S4, S5 |
| `127.0.0.1:9100` | ip-sm-gw `:9100` | bridge /metrics | — |

> Host UDP `5060` is the canonical Kamailio published port (`5060:5060/udp`).
> A host-level Asterisk previously held `0.0.0.0:5060` (hence an earlier
> `5066` + `MVNO_PUBLISH_5060` gating); that Asterisk is removed, so Kamailio
> now binds 5060 directly. On a fresh host with no competing SIP daemon, UDP
> 5060 is used as-is. See `ENVIRONMENT_MATRIX.md` §3.

### A.2 — Static container IPs on `mvno_net` (10.89.0.0/24, pinned in compose)

| Service | IP | Service | IP | Service | IP |
|---|---|---|---|---|---|
| mongodb | .4 | nrf | .11 | amf | .12 |
| smf | .13 | upf | .14 | ausf | .15 |
| bsf | .16 | udm | .17 | udr | .18 |
| pcf | .19 | nssf | .20 | open5gs-webui | .22 |
| kamailio | .23 | ueransim-gnb | .30 | ueransim-ue-1/2/3 | .31/.32/.33 |
| vector | .40 | victoria-metrics | .41 | vmagent | .42 |
| grafana | .43 | ai-filter | .44 | osmo-hlr | .45 |
| telecom-api | .46 | mongodb-exporter | .47 | rtpengine | .48 |
| osmo-smsc | .49 | 2g-core | .50 | 2g-ms | .51 |
| 2g-ms2 | .52 | ip-sm-gw | .53 | victorialogs | .57 |

Demo-only rigs (created by runbooks, not part of the 32-container core):
`ims-uas58` @ `10.89.0.58`, `ims-caller59` @ `10.89.0.59` (Flow E),
`baresip-rx/tx` @ `10.89.0.60/.61` (S4). All three IP pairs are **static by
convention** (passed as `--ip` on `podman run`) — if one is occupied, reuse the
same address plan (they are only used by demo containers). `.54–.56` are the
sms_matrix's transient receivers (`ims_rx54/55/56`) and `.58–.61` the demo
rigs — **do not reuse these for static services** (`make check-pins` guards
uniqueness in compose, not the runbook rigs).

### A.3 — Dynamic addresses (never hardcode — read at runtime)

| Address | Allocator | Notes |
|---|---|---|
| UE user-plane IPs `10.45.0.2 – 10.45.0.254` | SMF session pool (`smf.yaml`; `.1` = ogstun gateway excluded, Issue 5.7) | Re-allocated on **every** UE attach; `live_demo.sh` [5b] reads ue-1's `uesimtun0` IPv4 live (Issue 5.9 runbook fix). Current (2026-08-08): ue-1=10.45.0.5, ue-2=10.45.0.2, ue-3=10.45.0.4 |
| `10.45.0.1/16` | UPF `ogstun` N6 gateway (static config) | `ip addr replace … dev ogstun`; UE default route via this |
| SIP transport ports `:5070/:5071`, `:5090/:5091` | `sip_traffic_sim.py` `--listen-port` | Per-role convention, fixed in runbooks |
| Kamailio source IP of UE calls | UPF SNAT (`MASQUERADE 10.45.0.0/16 !ogstun`) | UE calls appear from `10.89.0.14`, not the UE IP (Issue 8.20) |
| Vosk/RTP spool file names | RTPEngine + `live_tap.sh` | `state/spool/pcaps/<pcap-stem>`; read via `newest.sh` |

---

## S11.1 — One command: personal SMS → MT → Wireshark (`watch_send`)

**PURPOSE** — S6/S11 for a *single* message you actually type, collapsed to one
command: send → watch it transit the network → confirm MT arrival → open the
packets in the **Wireshark GUI**. This is the smallest possible "the user sent
an SMS and it travelled to the phone" demo — no multi-terminal runbook.

```bash
# From the repo root (stack up). Send your own body to a 2G/5G recipient:
RECIP=15557654321 ; BODY="hello from my phone"
# 1) Send via the intercept gateway (real network, real MT):
bash scripts/testing/send_rest_sms.sh 15551234567 "$RECIP" "$BODY"
# 2) Watch it arrive on the 2G handset (poll the real phone's inbox):
podman exec mvno-2g-ms sh -c "sleep 6; grep \"$BODY\" /root/.osmocom/bb/sms.txt"
#   → prints the line → that's the MT receipt ("✓ arrived").
# 3) Prove transit on the bridge counters (2g5g / 5g2g delta):
curl -s localhost:9100/metrics | grep -E 'sms_(2g5g|5g2g)'
# 4) Open the newest relay pcap in the Wireshark GUI:
wireshark -r "$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')" \
  -d udp.port==10000-20000,rtp -Y 'sip || tcp || smpp || rtp'
```

**Call flow (same idea, voice):** start the cockpit (`bash scripts/demo/demo_live.sh
--wireshark --windowed`), SPEAK from pane P0, and the S11 `call` window P2 shows
the SIP/RTP live while the Wireshark GUI captures it — the call equivalent of step 4.

> **Why this (and not a new script/doc):** every primitive above already
> exists and is verified (`send_rest_sms.sh`, the `sms.txt` MT grep from
> `sms_matrix.sh`, `newest.sh`, the S11 `--wireshark` launcher). A dedicated
> `watch_send.sh` wrapper remains a **possible** convenience, but is not
> required to demonstrate the path — this section *is* the single-command demo
> using the pieces already shipped.

---

## S12 — USER-driven live flow (`make user-demo`) · the human drives

The AUTO/`make graduation`/`gate` path is canned and deterministic. The
**user-driven** companion takes LIVE, dynamic input from the operator — your
own SMS body and your own voice — reusing the same tested primitives (`send_rest_sms.sh`, `demo_call.sh`, `mic_record.sh`, `live_tap`, `NativeVoskService`).

### 1. Interactive Execution Order

```bash
# 1) Stack up (all containers, Vosk small-model + live-tap daemon)
make up

# 2) Confirm the microphone is audible (non-fatal)
bash scripts/demo/mic_probe.sh

# 3) USER SMS — type any body, pick any MVNO flow
make user-sms BODY="You have won a prize, call us now" FLOW=2g-2g
#   or interactively:
make user-demo            # menu → 3) User SMS

# 4) USER LIVE VOICE CALL — speak 10s, Vosk transcribes YOUR words
make user-call CALLEE=15559998888              # speak ~10 s, see your words live
#   or interactively:
make user-demo            # menu → 4) User Call

# 5) Evidence: scam-flag counters
curl -s localhost:8080/actuator/prometheus | grep mvno_vosk_scamflag
```

### 2. Auto vs User Comparison

| Entry | Auto (canned) | User (live/dynamic) |
|---|---|---|
| SMS | `sms_matrix.sh` / `demo_call.sh` (fixed bodies) | `user_sms.sh` — **you type** the body |
| Call | `demo_call.sh` / `graduation` (canned phrase) | `user_call.sh` — **you speak**, live Vosk |
| Voice | baresip UAs + `--codec g722` sim | your phone/softphone or the mic |

### 3. User SMS Flow Routing Table

`user_sms.sh "<body>" <flow>` — `<flow>` is one of:

| flow | route | sender → recipient |
|---|---|---|
| `2g-2g` | 2G SMSC direct | 15557778888 → 15554443322 |
| `2g-5g` | SMSC→SIP relay | 15554443322 → 15551234567 |
| `5g-2g` | bridge→SMPP | 15551234567 → 15554443322 |
| `5g-5g` | Kamailio twin | 15551234567 → 15557654321 |
| `ai` | 5G→5G AI-block | 15551234567 → 15557654321 (no delivery) |

Example — a real scam body flagged live (advisory-only, non-blocking):
```bash
make user-sms BODY="your bank account has been blocked, please verify your details" FLOW=5g-5g
```
The Interception Gateway runs balance $\rightarrow$ EIR $\rightarrow$ AI-spam. A scam keyword match
increments the review counter (`mvno_vosk_scamflag_total{word="..."}`) and returns **allow=true**
(NEVER hard-blocks the call/SMS) — adhering to the zero-trust advisory contract.

> **Exact phone / softphone values** (Linphone, MizuDroid, SipClient, baresip-UAs):
> proxy `sip:<HOST-LAN-IP>:5060` (discover `hostname -I | awk '{print $1}'`),
> username `15551234567`, password `testpass`,
> realm `localhost`, transport UDP/TCP. Dial `15559998888` (baresip-rx auto-answer).
> Negotiate **G.722/16000** (`rtpmap:9`) with **PCMU/8000** fallback — see
> `server-port` config in the client build.