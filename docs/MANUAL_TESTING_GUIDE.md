# MVNO Telecom Core — Manual Testing Guide

A hands-on, terminal-by-terminal guide for verifying **every** active flow in the MVNO
private-mobile-network core: **2G SMS, 5G/IMS SMS, 2G↔5G SMS bridging (IP-SM-GW),
SIP/IMS calls, RTPEngine media plane, Vosk speech-to-text, live call recording +
ASR transcription, Grafana alerting, the deterministic AI spam-block path, and the
automated demo/e2e gates**.

All commands below were **empirically verified** against the running stack
(`podman compose up`). Each flow is shown as a set of commands you paste into
**separate terminal windows** so you can watch each leg in real time.

> **Section 0 is the flagship**: a complete **from-zero live demo** that uses **only raw
> shell** — no Python, no calls to `./scripts/testing/*`. It uses `baresip`
> (a tiny native SIP UA) for voice, raw `nc`+`md5sum` for SIP digest SMS,
> raw binary SMPP over `nc` for 2G SMS, raw `sqlite3` for queue injection, and
> `tshark`+`xxd`+`ffmpeg` for the recording pipeline. Sections 1–3 and Flows A–O
> document the same flows in their scripted/containerized forms.

---

## Table of Contents

0. [From-Zero Live Demo (raw shell, no scripts, no Python)](#0-from-zero-live-demo-raw-shell-no-scripts-no-python)
1. [Prerequisites & Reference Data](#1-prerequisites--reference-data)
2. [Terminal Layout (suggested)](#2-terminal-layout-suggested)
3. [Quick reference — injectors](#3-quick-reference--injectors)
4. [Flow A — 2G → 2G SMS (SMSC store-and-forward)](#flow-a--2g--2g-sms-smsc-store-and-forward)
5. [Flow B — 2G → 5G SMS (IP-SM-GW bridge, leg 1)](#flow-b--2g--5g-sms-ip-sm-gw-bridge-leg-1)
6. [Flow C — 5G → 2G SMS (IP-SM-GW bridge, leg 2)](#flow-c--5g--2g-sms-ip-sm-gw-bridge-leg-2)
7. [Flow D — 5G → 5G SMS (IMS SMS-over-IP end-to-end)](#flow-d--5g--5g-sms-ims-sms-over-ip-end-to-end)
8. [Flow E — SIP/IMS Voice Call (RTPEngine anchored)](#flow-e--sipims-voice-call-rtpengine-anchored)
9. [Flows F–J — Telemetry, ASR, Recording, REST & Grafana (condensed)](#flows-fj--telemetry-asr-recording-rest--grafana-condensed)
10. [Flow K — AI Spam Block (deterministic E2E-BLOCK)](#flow-k--ai-spam-block-deterministic-e2e-block)
11. [Flow L — Automated E2E Gate (e2e_runbook.sh)](#flow-l--automated-e2e-gate-e2e_runbooksh)
12. [Flow M — Call Recording → ASR Transcription (RTPEngine pcap → WAV → Vosk)](#flow-m--call-recording--asr-transcription-rtpengine-pcap--wav--vosk)
13. [Flow N — Automated Demo Gate (demo_runbook.sh)](#flow-n--automated-demo-gate-demo_runbooksh)
14. [Flow O — Failure-Path & Resilience Checks](#flow-o--failure-path--resilience-checks)
15. [Troubleshooting & Known Quirks](#troubleshooting--known-quirks)

---

## 0. From-Zero Live Demo (raw shell, no scripts, no Python)

**Goal**: prove the whole core — voice, recording/ASR, spam verdict, and all five
SMS paths — using **only raw shell commands** and two `baresip` SIP UA containers.
Every command in this section was verified live on 2026-08-06.

**What you will prove, in order:**

1. 2G MS attached (mctest) — receiver for 2G SMS.
2. `baresip` voice call, auto-answered, media through RTPEngine.
3. pcap → `tshark`/`xxd`/`ffmpeg` → WAV in the spool → **Vosk transcript + AI spam
   verdict + metric deltas**.
4. All five SMS paths: 2G→2G (raw SMPP), 2G→5G (sqlite3), 5G→2G and 5G→5G
   (raw `nc` + MD5 digest), REST interception API.
5. AI spam **block** (E2E-BLOCK → `403` + counter).
6. Final automated gates (e2e 7/7 + demo 13/13).

### Step 0 — prereqs & stack

```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
for t in sqlite3 curl espeak-ng ffmpeg nc tshark xxd md5sum; do
  command -v $t >/dev/null || echo "MISSING: $t"
done
podman compose ps | grep -c Up          # expect 31 (containers of the stack)
```

### Step 1 — attach the 2G MS (keep this terminal)

```bash
podman exec -it mvno-2g-ms /bin/bash
cd /tmp && ./mctest -l /tmp/osmocom_l2 -P mm    # bring up MM layer toward MSC
```

The MS serves **MS1 / `15554443322`** (IMSI `001010000000004`). Every 2G-received
SMS lands in `/root/.osmocom/bb/sms.txt` as `[SMS from +<sender>]` + body lines —
this is your receipt for the 2G flows below.

### Step 2 — make the speech file + baresip configs

The receiver (rx) streams a **pre-recorded speech WAV** as its RTP audio, so the
recorded call actually contains words for Vosk.

```bash
# 1) A short spam-like phrase (matches the AI filter's keyword rule: won/prize/call)
espeak-ng -v en-us "You have won a prize, call us now" -w /tmp/speech.wav
mkdir -p state/baresip/rx state/baresip/tx

# 2) 8 kHz mono s16le speech WAV (aufile source format)
ffmpeg -y -loglevel error -i /tmp/speech.wav -ar 8000 -ac 1 -c:a pcm_s16le \
  state/baresip/speech8k.wav

# 3) baresip configs (note: account.so/menu.so/ctrl_tcp.so are APPLICATION modules)
cat > state/baresip/rx/config <<'EOF'
module_path /usr/lib/baresip/modules
module stdio.so
module g711.so
module ausine.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
audio_source aufile,/media/speech8k.wav
EOF
cat > state/baresip/rx/accounts <<'EOF'
<sip:15559998888@10.89.0.23:5060>;auth_user=15559998888;auth_pass=testpass;answermode=auto
EOF
cat > state/baresip/tx/config <<'EOF'
module_path /usr/lib/baresip/modules
module stdio.so
module g711.so
module ausine.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
EOF
cat > state/baresip/tx/accounts <<'EOF'
<sip:15553332211@10.89.0.23:5060>;auth_user=15553332211;auth_pass=testpass
EOF
```

> baresip runs **inside a rootless-Podman container** on `mvno_mvno_net` — a bare
> host process cannot dial a loopback/container IP (`ua: no laddr for 127.0.0.1`,
> EINVAL) because the host has no address on `10.89.0.0/24` (see Troubleshooting #9).
> The container borrows the host-installed baresip binary + libs (no new image work):
> `ubuntu:24.04` provides glibc ≥ 2.38 which baresip 4.6.0 requires
> (Debian bookworm's glibc 2.36 is too old).

### Step 3 — run the two baresip terminals

```bash
# Shared read-only mount list: the baresip binary, its 9 shared libs, its modules
# (an ARRAY — zsh doesn't word-split plain variables; keep ${f} braces for the :ro suffix)
B=(-v /usr/bin/baresip:/usr/bin/baresip:ro)
for f in /usr/lib/libbaresip.so.26 /usr/lib/libre.so.41 \
         /usr/lib/libbrotlicommon.so.1 /usr/lib/libbrotlidec.so.1 \
         /usr/lib/libbrotlienc.so.1 /usr/lib/libcrypto.so.3 \
         /usr/lib/libssl.so.3 /usr/lib/libz.so.1 /usr/lib/libzstd.so.1; do
  B+=(-v "${f}:${f}:ro")
done
B+=(-v /usr/lib/baresip:/usr/lib/baresip:ro)

# Receiver (auto-answer; streams the speech WAV as its audio). Own IP on the net.
podman rm -f baresip-rx baresip-tx 2>/dev/null
podman run -d --name baresip-rx --network mvno_mvno_net --ip 10.89.0.60 \
  "${B[@]}" -v $PWD/state/baresip/rx:/cfg:z \
  -v $PWD/state/baresip/speech8k.wav:/media/speech8k.wav:ro \
  docker.io/library/ubuntu:24.04 baresip -f /cfg -s -T

# Caller (has a ctrl_tcp console on 127.0.0.1:4444 inside the container)
podman run -d --name baresip-tx --network mvno_mvno_net --ip 10.89.0.61 \
  "${B[@]}" -v $PWD/state/baresip/tx:/cfg:z \
  docker.io/library/ubuntu:24.04 baresip -f /cfg -s -T

# Registration proof: each 401-then-200 OK pair = one authenticated REGISTER
sleep 3
podman logs baresip-rx | grep -c "200 OK"      # expect >= 2
podman logs baresip-tx | grep -c "200 OK"      # expect >= 2
```

> Do **not** run baresip with `-d` (daemonize) — registration then goes silent
> (a baresip quirk); run it backgrounded exactly as above (`-s` = no SIGINT
> handling, `-T` = trace). To change config or speech: edit the files, then
> `podman rm -f baresip-rx baresip-tx` and re-run Step 3.

### Step 4 — make the voice call (caller terminal)

```bash
# Dial the receiver (JSON command over ctrl_tcp, netstring framing <len>:<json>,)
MSG='{"command":"dial","params":"sip:15559998888@10.89.0.23:5060"}'
podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; \
  printf '${#MSG}:${MSG},' >&3; timeout 2 cat <&3"
#  ^ host shell expands ${#MSG} before podman exec — that's the netstring length
```

Expected: a `CALL_OUTGOING` event; the rx answers automatically. Let RTP flow
**~12 seconds** (the speech file is ~2.3 s, aufile loops it), then hang up:

```bash
MSG='{"command":"hangup"}'
podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; \
  printf '${#MSG}:${MSG},' >&3; timeout 2 cat <&3"
podman logs baresip-rx | grep -c "200 Answering"    # expect 1
ls -t state/spool/pcaps/*.pcap | head -1            # the fresh recording
```

**Expected** (in the rx log): `INVITE sip:15559998888@...`, `180 Ringing`,
`200 Answering` with `m=audio <port> RTP/AVP 0 8 101`, then `BYE` on hangup.
RTPEngine recorded every call — a new pcap file (~450 KB) appears in
`state/spool/pcaps/`.

### Step 5 — pcap → WAV → spool → Vosk verdict

Raw extraction: RTP media ports are **even** (RTCP = odd), and the **shorter**
media leg is the speech file (the caller's sine tone runs the whole call):

```bash
NEW=$(ls -t state/spool/pcaps/*.pcap | head -1)
P=$(tshark -r "$NEW" -Y "udp.dstport%2==0" -T fields -e udp.dstport \
    | sort | uniq -c | sort -n | head -1 | awk '{print $2}')
# G.711 PCMU (pt 0) payloads, raw u-law bytes:
tshark -r "$NEW" -d udp.port==$P,rtp -Y "rtp.payload && rtp.p_type==0" \
  -T fields -e rtp.payload | xxd -r -p > /tmp/call.mulaw
# u-law 8 kHz -> 16 kHz mono WAV, dropped into the Vosk spool:
ffmpeg -y -loglevel error -f mulaw -ar 8000 -ac 1 -i /tmp/call.mulaw \
  -ar 16000 -ac 1 state/spool/baresip-call.wav
ls -la /tmp/call.mulaw        # ~117 pkts x 160 B = ~18.7 KB for a 2.3 s speech
```

> **tshark gotcha**: the payload-type field is **`rtp.p_type`** — `rtp.pt` is not a
> valid filter field and silently yields nothing. The `-d` override must name the
> **rtpengine-side destination port** (src-port overrides are a silent no-op).

Then let the ASR watcher (~3 s poll) do its work and read the verdict:

```bash
sleep 12
cat state/spool/archived/baresip-call.txt           # JSON {"text": "..."}
podman logs mvno-api 2>&1 | grep "AI transcript verdict" | tail -2
curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_classified_total' \
  | grep -o '"value":\[[0-9.]*,"[0-9]*"\]'
curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total' \
  | grep -o '"value":\[[0-9.]*,"[0-9]*"\]'
```

**Expected** (certified 2026-08-06 run): transcript
`{"text": "you have won a prime target now"}` (small-model fuzz of the phrase —
the keyword rule catches "won"), verdict
`AI transcript verdict [baresip-call]: allow=false, reason='Spam (phishing phrase detected)'`,
and **both** counters increment (`mvno_vosk_classified_total` and
`mvno_vosk_blocked_total`). For a clean phrase, expect `allow=true,
reason='Clean content'` and only `mvno_vosk_classified_total` moving.

### Step 6 — the five SMS paths

**6a. 2G → 2G (raw binary SMPP over nc, port 2775).** Binds as ESME
`smsclient`/`password`, then SUBMIT_SM `15557778888 → 15554443322` (MS1, which is
the only MS that logs receipts):

```bash
( printf '\x00\x00\x00\x28\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x01smsclient\x00password\x00\x00\x34\x00\x00\x00'; \
  sleep 1; \
  printf '0000004500000004000000000000000200010131353535373737383838380001013135353534343433333232000000000000000000000e48656c6c6f207261772032473247' | xxd -r -p ) \
  | nc -q 3 localhost 2775 | xxd | head -3
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```

Expected: first response = `8000 0009` bind OK; SMSC log
(`podman logs mvno-osmosmsc`) shows `Rx BIND Trx`, `Rx SUBMIT-SM (15554443322/1/1)`
and `SMPP SUBMIT-SM: Stored in DB`; the MS prints
`[SMS from +15557778888]` / `Hello raw 2G2G` in `sms.txt`. The bridge is **not**
involved (its `mvno_bridge_sms_*` counters stay flat).

> The SMPP PDU bytes are exact (verified against the SMSC parser): header
> `00 00 00 45 | 00 00 00 04 | 00 00 00 00 | 00 00 00 02` then
> `00 01 01 <src 11 digits> 00 01 01 <dst 11 digits> 00 00 00 00 00 00 00 00 00 00 0e <14-byte body>`.
> Change the body: keep it 14 bytes and update the `0e` length byte, or rebuild the
> PDU with `scripts/testing/send_smpp_sms.py` as a reference.

**6b. 2G → 5G (raw sqlite3 INSERT into the bridge's queue).** The bridge polls
`state/hlr/smsc.db` every ~3 s:

```bash
sqlite3 state/hlr/smsc.db "INSERT INTO SMS (created, deliver_attempts,
  reply_path_req, status_rep_req, is_report, msg_ref, protocol_id,
  data_coding_scheme, ud_hdr_ind, src_addr, src_ton, src_npi,
  dest_addr, dest_ton, dest_npi, text) VALUES (datetime('now'), 0, 1, 0, 0,
  1, 0, 0, 0, '15554443322', 1, 1, '15559998888', 1, 1, 'Hello raw 2G5G');"
sleep 8
podman logs mvno-ip-sm-gw --since 2m | grep -E "POLL|DELIVERED" | tail -2
podman logs baresip-rx 2>&1 | grep "Hello raw 2G5G"        # MESSAGE body seen
```

Expected: bridge `[POLL] row_id=NN ...` → `[DELIVERED] row_id=NN marked sent`,
Kamailio relays the MESSAGE, and baresip-rx prints the body. Cleanup afterwards
(so the e2e gate isn't polluted):

```bash
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"
```

**6c. 5G → 2G (raw nc + MD5 digest, Kamailio 5066).** One-shot SIP MESSAGE with
digest auth — 407, compute the response, resend:

```bash
cd /tmp && USER=15553332211 REALM=10.89.0.23 PASS=testpass \
  URI='sip:15554443322@10.89.0.23:5060' BODY='Hello raw 5G2G'
# 1) unauth'd MESSAGE -> 407 with a nonce
printf 'MESSAGE %s SIP/2.0\r\nVia: SIP/2.0/UDP 10.89.0.62:5070;branch=z9hG4bK1;rport\r\nFrom: <sip:%s@%s>;tag=1\r\nTo: <sip:15554443322@%s>\r\nCall-ID: c1@10.89.0.62\r\nCSeq: 1 MESSAGE\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s' "$URI" "$USER" "$REALM" "$REALM" "${#BODY}" "$BODY" > m1.txt
NONCE=$(timeout 5 nc -u localhost 5066 < m1.txt | grep -oE 'nonce="[^"]+"' | head -1 | sed 's/nonce="\(.*\)"/\1/')
# 2) digest = md5 of HA1/HA2 per RFC 2617
HA1=$(printf '%s:%s:%s' "$USER" "$REALM" "$PASS" | md5sum | cut -d' ' -f1)
HA2=$(printf 'MESSAGE:%s' "$URI" | md5sum | cut -d' ' -f1)
RESP=$(printf '%s:%s:%s' "$HA1" "$NONCE" "$HA2" | md5sum | cut -d' ' -f1)
# 3) resend with Proxy-Authorization -> 200 OK
printf 'MESSAGE %s SIP/2.0\r\nVia: SIP/2.0/UDP 10.89.0.62:5070;branch=z9hG4bK2;rport\r\nFrom: <sip:%s@%s>;tag=2\r\nTo: <sip:15554443322@%s>\r\nCall-ID: c1@10.89.0.62\r\nCSeq: 2 MESSAGE\r\nProxy-Authorization: Digest username="%s", realm="%s", nonce="%s", uri="%s", response="%s", algorithm=MD5\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s' "$URI" "$USER" "$REALM" "$REALM" "$USER" "$REALM" "$NONCE" "$URI" "$RESP" "${#BODY}" "$BODY" > m2.txt
timeout 5 nc -u localhost 5066 < m2.txt | grep -E "^SIP"
sleep 8
podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2
```

Expected: `SIP/2.0 200 OK`; the bridge logs `[RELAY] 5G->2G 15553332211->
15554443322 body='Hello raw 5G2G'` + `[SMPP] BIND_TRANSCEIVER OK` +
`[SMPP] SUBMIT_SM OK`; MS1 prints `[SMS from +15553332211]` / `Hello raw 5G2G`.

> **MS2 trap**: an SMS addressed to `15557778888` is accepted by the SMSC but is
> **never** seen in `sms.txt` — the 2G container serves only MS1 (`15554443322`).
> Always use `15554443322` as the 2G recipient for receipt checks.

**6d. 5G → 5G (raw nc + digest, same as 6c but to a registered IMS number):**

```bash
cd /tmp && USER=15553332211 REALM=10.89.0.23 PASS=testpass \
  URI='sip:15559998888@10.89.0.23:5060' BODY='Hello raw 5G5G'
# ...same 3-step nonce/digest dance as 6c (different URI/Call-ID)...
timeout 5 nc -u localhost 5066 < m2.txt | grep -E "^SIP"
podman logs baresip-rx 2>&1 | grep "Hello raw 5G5G"        # body received
```

Expected: `SIP/2.0 200 OK` and the baresip-rx console shows the MESSAGE body —
pure IMS SMS, no bridge/SMPP involvement (bridge counters stay flat).

**6e. REST interception API (clean + block):**

```bash
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender": "15551234567", "recipient": "15557654321", "content": "Hello MVNO 5G"}'
# -> {"allow":true,"reason":"Clean content"}
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender": "15551234567", "recipient": "15557654321", "content": "E2E-BLOCK REST test"}'
# -> {"allow":false,"reason":"Spam (E2E deterministic block)"}
```

### Step 7 — AI spam block over SIP (E2E-BLOCK → 403)

Same digest dance as 6c/6d, but the body contains the `E2E-BLOCK` marker. The
inline AI-filter mock (`docker-compose.yml`) returns `allow:false` for it, so
Kamailio rejects the MESSAGE with **403**:

```bash
cd /tmp && USER=15553332211 REALM=10.89.0.23 PASS=testpass \
  URI='sip:15559998888@10.89.0.23:5060' BODY='E2E-BLOCK urgent offer'
# ...same nonce/digest dance...
timeout 5 nc -u localhost 5066 < m2.txt | grep -E "^SIP"    # SIP/2.0 403 SMS Intercepted / Blocked
sleep 5
curl -s http://localhost:8080/actuator/prometheus | grep ^mvno_sms_blocked_total
podman logs mvno-kamailio --since 2m | grep -c "SMS BLOCKED BY MVNO INTERCEPTION CORE"   # >= 1
podman logs baresip-rx 2>&1 | grep -c "urgent offer"        # 0 — never delivered
```

Expected: `SIP/2.0 403 SMS Intercepted / Blocked`, the actuator counter
`mvno_sms_blocked_total` **increments**, Kamailio logs the block, and the
receiver never sees the body. (Verified: counter `7.0 -> 8.0` on the 2026-08-06 run.)

### Step 8 — final automated gates

```bash
sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"   # drain leftover demo rows
./scripts/testing/e2e_runbook.sh ; echo "exit=$?"                 # ALL CELLS PASS, exit=0
./scripts/testing/demo_runbook.sh ; echo "exit=$?"                # ALL 13 PASSED, exit=0
podman rm -f baresip-rx baresip-tx        # demo cleanup
```

---

## 1. Prerequisites & Reference Data

Ensure the full stack is up and healthy **before** running any flow:

```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
podman compose ps          # expect 31/31 containers Up
./scripts/preflight.sh     # optional health preflight
```

### Reference numbers (subscribers)

| Role | MSISDN | IMSI | 2G or 5G | Registered where |
| :--- | :--- | :--- | :--- | :--- |
| 5G UE-1 | `15551234567` | `001010000000001` | 5G | Open5GS AMF + Kamailio (IMS) |
| 5G UE-2 | `15557654321` | `001010000000002` | 5G | Open5GS AMF + Kamailio (IMS) |
| 5G UE-3 | `15559998888` | `001010000000003` | 5G | Open5GS AMF + Kamailio (IMS) |
| 2G MS-1 | `15554443322` | `001010000000004` | 2G (GERAN) | OsmoMSC / VLR (attached) |
| 2G MS-2 | `15557778888` | `001010000000005` | 2G (GERAN) | OsmoMSC / VLR (attached) |

- All SIP digest passwords default to `testpass`.
- Kamailio SIP host: `10.89.0.23` (container) / `127.0.0.1:5066` (host-mapped).
- Keys: `mvno-demo-key-2026`.
- 5G IMS SMS recipients used in raw demos: `15559998888` (baresip rx),
  `15553332211` (baresip tx — sender). **2G receipt checks always use
  `15554443322` (MS1)** — MS2's receipts never appear in `sms.txt`.

### Key services & ports (host-facing)

| Service | Host endpoint |
| :--- | :--- |
| Interception Gateway (Spring Boot) | `http://localhost:8080` |
| AI Spam Filter (inline mock, E2E-BLOCK rule) | `http://localhost:8008` |
| SMPP 3.4 (OsmoSMSC ESME) | `127.0.0.1:2775` |
| Kamailio SIP (host-mapped) | `127.0.0.1:5066` |
| IP-SM-GW bridge metrics | `http://localhost:9100/metrics` |
| VictoriaMetrics PromQL | `http://localhost:8428` |
| Grafana | `http://localhost:3000` (admin/admin) |

> The OsmoSMSC **VTY (127.0.0.1:4254) is not published** and the container has no
> `nc`/`socat` — the old `send_vty_sms.sh` driver is **broken by design**; use the
> raw SMPP/nc commands in Section 0.6a or `send_smpp_sms.py`.

---

## 2. Terminal Layout (suggested)

Open these terminal tabs and keep them running *before* you start a flow:

| Tab | Purpose | Command to start in that tab |
| :--- | :--- | :--- |
| **T0** | IP-SM-GW bridge logs | `podman logs -f mvno-ip-sm-gw` |
| **T1** | Kamailio (syslog) | `podman logs -f mvno-kamailio 2>&1 \| grep -iE 'message\|relay\|sms'` |
| **T2** | OsmoSMSC / MSC logs | `podman logs -f mvno-osmosmsc 2>&1 \| tail -f` |
| **T3** | SMS queue state | `watch -n2 'sqlite3 state/hlr/smsc.db "SELECT id,src_addr,dest_addr,text,sent,deliver_attempts FROM SMS;"'` |
| **T4** | 2G MS receiver (to receive SMS) | see Flow A |
| **T5** | 5G/IMS terminal (receiver or sender) | see Flow B/C/D |
| **T6** | Voice UAS terminal (answers the call, streams RTP) | see Flow E |
| **T7** | Voice caller terminal (dials, streams RTP, hangs up) | see Flow E |
| **T8** | RTPEngine / VictoriaMetrics live counters | `watch -n1 "curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_packets_total' \| grep -o '\"value\":.*' ; curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_bytes_total' \| grep -o '\"value\":.*'"` |

### Reusable helper — dedicated IMS terminal container

Every 5G/IMS sender or receiver runs as a **dedicated container with its own IP**
on `mvno_mvno_net` (the proven `e2e_runbook.sh` pattern — mirrors the Goal 6
receiver topology and does **not** depend on the UERANSIM 5G user-plane):

```bash
# Receiver: registers with Kamailio, then listens for SIP MESSAGEs
podman run -d --name ims-rx --network mvno_mvno_net --ip 10.89.0.54 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode recv --msisdn 15551234567 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.54
podman logs -f ims-rx          # watch incoming "<sender>: <body>" lines

# Sender: registers, sends one MESSAGE, exits
podman run -d --name ims-tx --network mvno_mvno_net --ip 10.89.0.55 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15554443322 --body "Hello from IMS" \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.55
podman logs ims-tx             # expect "[+] MESSAGE delivered (digest)"

# Cleanup when done
podman rm -f ims-rx ims-tx
```

> **Raw-shell alternative** for the same roles: Section 0.2–0.3 (baresip receiver) and
> Section 0.6c/6d (nc+digest sender) — no Python involved.

Free static IPs reserved for this: **10.89.0.54 / 10.89.0.55 / 10.89.0.56**
(SMS terminals), **10.89.0.58 / 10.89.0.59** (voice UAS / caller — see Flow E),
**10.89.0.60 / 10.89.0.61** (baresip rx / tx — see Section 0).
All SIP digest passwords default to `testpass`; registered subscribers live in
Kamailio's `subscriber` table.

> In-UE alternative (uses the real 5G SA user plane): `podman exec -it
> mvno-ueransim-ue-1 ...` — see the note under Flow B. Requires the
> `ip route replace 10.89.0.23/32 dev uesimtun0` inside the UE container.

**Golden rule**: give each agent (receiver, bridge, sender) its **own IP/container**.
Do **not** run the receiver in the same container as the bridge (`mvno-ip-sm-gw`),
or Kamailio sees a source-IP ambiguity and relays loop / 408s (see Troubleshooting).

---

## 3. Quick reference — injectors

These tools inject an MO/MT SMS into OsmoSMSC's `store-and-forward` queue or into
the IMS interception path. The IP-SM-GW bridge drains rows targeting a 5G
subscriber (Flow B), and rows targeting a 2G subscriber are delivered natively by
OsmoSMSC to the attached 2G MS (Flow A).

```bash
# A) Raw SQLite injection into the SMSC queue — the canonical 2G->5G row driver
#    (writes the bridge's real polled SMS table: state/hlr/smsc.db, deliver_attempts=0)
#    Full command in S0.6b. Scripted equivalent:
python3 scripts/testing/inject_smsc_row.py 15554443322 15551234567 "Hello via DB queue"

# B) Raw binary SMPP 3.4 submit_sm (port 2775) — the same path the IP-SM-GW uses
#    Full command in S0.6a. Scripted equivalent:
python3 scripts/testing/send_smpp_sms.py --sender 15554443322 --recipient 15557654321

# C) Via the Gateway REST interception API (evaluates balance/EIR/spam policies)
#    Raw curl in S0.6e. Scripted equivalent:
./scripts/testing/send_rest_sms.sh 15554443322 15557654321 "Hello via REST API"
```

> **Do NOT use `send_db_sms.sh`** (invented `sms`/`sender_id` schema writing to a
> different DB than the bridge polls — the row is never seen) and do **not** use
> the retired `send_vty_sms.sh` (the SMSC VTY is unpublished and the container
> lacks `nc`/`socat` — see Section 1). Prefer the raw commands in Section 0.
>
> To hit the **2G→5G bridge** use a 5G `recipient` (e.g. `15551234567`); to keep it
> **2G→2G** use a 2G `recipient` (e.g. `15557778888`).

---

## Flow A — 2G → 2G SMS (SMSC store-and-forward)

**Goal**: prove native 2G SMS delivery between two 2G subscribers through OsmoSMSC.

**Verify in**: T2 (OsmoSMSC logs), T3 (queue state).

### Terminal T4 — 2G MS receiver (run first)

```bash
podman exec -it mvno-2g-ms /bin/bash
# Use the Osmocom mobile terminal utility built into the container.
# (mctest / vtycmd live in /tmp/ of the container)
cd /tmp
./mctest -l /tmp/osmocom_l2 -P mm    # bring up MM layer toward MSC
```

### Terminal T0 — trigger an MO 2G→2G SMS

Any of the send tools in Section 3 with a **2G recipient**. Native delivery needs the
recipient 2G MS attached to the VLR. The raw way (full PDU command in Section 0.6a):

```bash
# sender 15557778888 -> recipient 15554443322 (MS1, logs receipts):
# paste the "( printf '<bind hex>' ; sleep 1; printf '<submit hex>' | xxd -r -p ) \
#   | nc -q 3 localhost 2775" block from S0.6a, changing the message bytes if desired.
```

Or the scripted way:

```bash
python3 scripts/testing/send_smpp_sms.py --sender 15557778888 --recipient 15554443322 \
  --message "2Gto2G Native SMS"
```

**Expected**:
- OsmoSMSC delivers to the attached 2G MS (immediate MT, no store-and-forward row).
- The 2G MS receiver terminal prints the incoming SMS.
- The received SMS is persisted on the handset: `podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt` shows the body.
- Queue table shows **no** lingering unsent row for a 2G destination.

---

## Flow B — 2G → 5G SMS (IP-SM-GW bridge, leg 1)

**Goal**: an SMS injected on the 2G side for a **5G** subscriber is bridged by
`mvno-ip-sm-gw`, relayed by Kamailio, and received by the 5G terminal.

**Verify in**: T0 (bridge log: `POLL` → `DELIVERED`), T2, T3.

### Terminal T5 — 5G receiver (dedicated container, own IP)

baresip receiver (Section 0.2–0.3, raw) or:

```bash
podman run -d --name ims-rx --network mvno_mvno_net --ip 10.89.0.54 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode recv --msisdn 15551234567 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.54
podman logs -f ims-rx     # watch for "15554443322: <body>"
```

> The receiver must be **registered with Kamailio** before the bridge polls the row
> (`--mode recv` registers automatically; expect `[+] IMS REGISTER 200 OK`).
>
> In-UE alternative (real 5G SA user plane, requires working attach): inside the
> UE container (`podman exec -it mvno-ueransim-ue-2 /bin/bash`) first add the route
> `ip route replace 10.89.0.23/32 dev uesimtun0`, then
> `python3 /scripts/ims_terminal.py --mode recv --msisdn 15551234567 \
> --host 10.89.0.23 --port 5060 --bind-ip <ue-tun-ip>`.

### Terminal T0 — inject the 2G→5G SMS

```bash
# Raw (canonical — full command in Section 0.6b): sqlite3 INSERT with src 15554443322,
# dest 15559998888 (or 15551234567), text 'E2E 2Gto5G'
# Scripted equivalent:
python3 scripts/testing/inject_smsc_row.py 15554443322 15551234567 "E2E 2Gto5G"
```

**Expected bridge log** (watch T0, within one poll cycle ~3s):

```
[POLL] row_id=NN 15554443322->15551234567 body='E2E 2Gto5G'
[DELIVERED] row_id=NN marked sent
```

**Expected**:
- Kamailio (T1) relays the SIP MESSAGE to the registered 5G terminal.
- The 5G receiver replies `200 OK` and prints `15554443322: E2E 2Gto5G`.
- In T3, the row's `sent` is no longer `NULL`.
- Bridge metric increments: `curl -s http://localhost:9100/metrics | grep mvno_bridge_sms_2g_to_5g_total`.

---

## Flow C — 5G → 2G SMS (IP-SM-GW bridge, leg 2)

**Goal**: a 5G/IMS subscriber sends a SIP MESSAGE to a 2G number; the bridge
receives it, acks Kamailio, and injects it into OsmoSMSC via SMPP for 2G delivery.

**Verify in**: T0 (bridge log: `[RELAY] 5G->2G`, `[SMPP] BIND_TRANSCEIVER OK`,
`[SMPP] SUBMIT_SM OK`), T2, T3.

### Terminal T5 — 5G sender

Raw (`nc` + MD5 digest — full nonce/digest sequence in Section 0.6c; recipient
`15554443322`), or scripted:

```bash
podman run -d --name ims-tx --network mvno_mvno_net --ip 10.89.0.55 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15554443322 --body "E2E 5Gto2G" \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.55
podman logs ims-tx     # expect "[+] MESSAGE delivered (digest): 15551234567 -> 15554443322"
```

**Expected bridge log** (watch T0):

```
[RELAY] 5G->2G 15551234567->15554443322 body='E2E 5Gto2G'
[SMPP] BIND_TRANSCEIVER OK
[SMPP] SUBMIT_SM OK 15551234567 -> 15554443322
```

**Expected**:
- The sender receives its final `200 OK` (transactional digest response).
- The 2G MS receiver prints the SMS (MS already attached → immediate MT); the
  body is also persisted in `mvno-2g-ms:/root/.osmocom/bb/sms.txt`.
- Because the 2G recipient is attached, OsmoSMSC delivers immediately and does
  **not** create a new store-and-forward row.
- Exactly **one** `[RELAY]` line per sent SMS (see Troubleshooting #6 if you see
  repeated relays — duplicate-delivery regression).

---

## Flow D — 5G → 5G SMS (IMS SMS-over-IP end-to-end)

**Goal**: pure IMS/SIP SMS between two 5G terminals through Kamailio with **no**
bridge involvement.

**Verify in**: T1 (Kamailio relay), T5 (both terminals).

Raw (`nc` + digest to a registered IMS number — Section 0.6d, receiver = baresip rx on
`15559998888`), or scripted:

### Terminal T5a — receiver (dedicated container)

```bash
podman run -d --name ims-rx56 --network mvno_mvno_net --ip 10.89.0.56 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode recv --msisdn 15557654321 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.56
podman logs -f ims-rx56
```

### Terminal T5b — sender (dedicated container)

```bash
podman run -d --name ims-tx55 --network mvno_mvno_net --ip 10.89.0.55 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15557654321 --body "E2E 5Gto5G" \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.55
podman logs ims-tx55
```

**Expected**:
- T1 shows Kamailio relaying the SIP MESSAGE to the receiver terminal.
- The receiver prints the incoming IMS SMS (`15551234567: E2E 5Gto5G`).
- No `[RELAY] 5G->2G` and no SMPP traffic in T0 (both endpoints are 5G) — bridge
  counters stay flat:
  `curl -s http://localhost:9100/metrics | grep -E "mvno_bridge_sms_(2g_to_5g|5g_to_2g)_total"`.

---

## Flow E — SIP/IMS Voice Call (RTPEngine anchored, full media dialog)

**Goal**: establish a real end-to-end SIP INVITE dialog between two IMS terminals with
media anchored through RTPEngine: **407 → 100 → 180 → 200 OK → ACK → RTP ↔ → BYE → 200**.
The caller streams G.711 PCMU RTP for N seconds and hangs up; the UAS answers, counts
the RTP it received, and streams its own leg back. Every call is **recorded to pcap** by
RTPEngine (see Flow M for the transcript pipeline).

**Verify in**: T6 (UAS), T7 (caller), T8 (RTP counters), T1 (Kamailio).

> **No-scripts alternative**: Section 0.2–0.4 (baresip rx auto-answers and streams a
> speech file; tx dials over its ctrl_tcp console) — verified 2026-08-06.
> The scripted simulator below remains the certified *programmatic* dialog.
>
> Each role must run in its **own container with its own IP** on `mvno_mvno_net`
> (10.89.0.58 / 10.89.0.59). The script binds its listen socket to that IP before
> registering, so Kamailio's `fix_nated_contact()` stores a reachable contact — an
> unbound register stores the socket's ephemeral port, which dies with the process
> and calls silently 408 (see ISSUES.md Section 8.27).

### Terminal T6 — UAS (answer the call, run first)

```bash
podman run -d --name ims-uas58 --network mvno_mvno_net --ip 10.89.0.58 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/sip_traffic_sim.py --uas 15559998888 --rtp 5 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.58 --listen-port 5070
podman logs -f ims-uas58
```

**Expected** (watch it register, then answer):

```
[+] SIP REGISTER 200 OK for subscriber 15559998888
[UAS] registered 15559998888, listening 10.89.0.58:5070 (media 10.89.0.58:5071)
[UAS] <- INVITE sip:15559998888@10.89.0.23:5060 SIP/2.0
[UAS] <- ACK sip:15559998888@10.89.0.58:5070 SIP/2.0
[UAS] outgoing RTP sent: 248 packets to 10.89.0.59:5091
[UAS] <- BYE sip:15559998888@10.89.0.58:5070 SIP/2.0
[UAS] call ended; RTP payload bytes received: 47520
```

### Terminal T7 — caller (dial + stream + hang up)

```bash
podman run -d --name ims-caller59 --network mvno_mvno_net --ip 10.89.0.59 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/sip_traffic_sim.py --rtp 6 --caller 15551234567 \
  --callee 15559998888 --host 10.89.0.23 --port 5060 \
  --bind-ip 10.89.0.59 --listen-port 5090
podman logs -f ims-caller59
```

**Expected** (full dialog trace):

```
=== Full IMS call with RTP media (15551234567 -> 15559998888, 6s) ===
    <- SIP/2.0 407 Proxy Authentication Required
    <- SIP/2.0 100 Trying
    <- SIP/2.0 180 Ringing
    <- SIP/2.0 200 OK
[+] call answered; media -> 10.89.0.58:5071
[+] RTP media sent: 297 packets to 10.89.0.58:5071
    <- SIP/2.0 200 OK
```

### Terminal T8 — live RTPEngine counters (while the call runs)

```bash
watch -n1 "curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_packets_total' | grep -o '\"value\":.*'; \
  curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_bytes_total' | grep -o '\"value\":.*'"
```

**Expected**: both counters jump **while the call is up** and freeze after BYE.
Reference figures from the certified 2026-08-05 run (`--rtp 6` caller / `--rtp 5` UAS):

```
rtpengine_packets_total  0  -> 546   (298 caller + 248 UAS packets, both legs through the media proxy)
rtpengine_bytes_total    0  -> 93912
rtpengine_closed_sessions_total{reason="terminated"}  +1  (Kamailio rtpengine_delete on BYE)
```

> **Counter reset caveat**: `rtpengine_*` counters reset whenever the rtpengine
> container is (re)created (they are process-local, not persisted). Always measure
> the **delta** across a call, never the absolute value. Accounting is flushed on
> the exporter's own tick after session close (observed 0-60 s after BYE) — poll
> the counter until it moves rather than reading once.

Cross-checks (all expected to pass):

```bash
# Session created and closed cleanly after BYE:
curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_sessions_total'        # +1 per call
curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_closed_sessions_total' # +1 after BYE
# Zero-packet fault counter stays flat (healthy media):
curl -s 'http://localhost:8428/api/v1/query?query=rtpengine_zero_packet_streams_total'
# Kamailio relayed the dialog:
podman logs mvno-kamailio --since 3m | grep -iE 'INVITE|ACK|BYE' | head
```

### Cleanup

```bash
podman rm -f ims-uas58 ims-caller59
```

> Legacy smoke test (no media): `python3 scripts/testing/sip_traffic_sim.py`
> (defaults: host `127.0.0.1:5066`, registers the callee, sends one digest INVITE).
> This still works from the host for a quick `407 → 100 → 200` check, but the full
> media dialog above is the certified flow.

---

## Flows F–J — Telemetry, ASR, Recording, REST & Grafana (condensed)

### Flow F — RTPEngine media plane metrics

```bash
curl -s http://localhost:9900/metrics | grep -i rtpengine | head   # direct scrape
```

**Expected (Grafana)**: the **RTP ENGINE DEEP DIVE** row shows `rtpengine_sessions_total`
and packet/byte counters incrementing while calls are active, and the **Active RTP
Sessions** gauge shows the live call. The **Zero-Packet RTP Streams (media stuck)**
panel stays green on healthy calls.

> The single authoritative RTPEngine metric is **`rtpengine_sessions_total`**.
> The older names `rtpengine_active_calls` / `rtpengine_sessions_total_count`
> **do not exist** in the current scrape set and show as 0-data panels.

### Flow G — Vosk Speech-to-Text ASR (spool quick test)

Vosk ASR runs **in-process inside `mvno-api`** (no separate Vosk container). Drop a
16 kHz mono WAV in the spool; the watcher (~3 s poll) writes
`state/spool/archived/<name>.txt`:

```bash
podman compose ps | grep mvno-api
ls vendor/vosk/vosk-model-small-en-us-0.15/   # mounted model (ro)
cp sample.wav state/spool/
sleep 5 && cat state/spool/archived/sample.txt
```

### Flow H — Live microphone recording + transcription

```bash
./scripts/testing/record_mic_call.sh 5        # records 5 s -> spool -> transcript
```

The script auto-falls back through `ffmpeg -f pulse` → `ffmpeg -f alsa` → `arecord`,
so it works on PulseAudio, ALSA and PipeWire hosts. (Raw pipeline for a *recorded*
call is Section 0.5; raw mic = `ffmpeg -f pulse -i default -ar 16000 -ac 1 state/spool/mic.wav`.)

### Flow I — Interception Gateway REST API

```bash
curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"sender": "15551234567", "recipient": "15557654321", "content": "Clean SMS"}'
# -> {"allow": true, "reason": "Clean content"}
```

Direct content-classification check against the AI filter mock:

```bash
curl -s http://localhost:8008/api/v1/classify -d '{"content":"clean text"}'      # {"allow":true,...}
curl -s http://localhost:8008/api/v1/classify -d '{"content":"E2E-BLOCK x"}'     # {"allow":false,...}
```

### Flow J — Grafana NOC & VictoriaMetrics telemetry

```bash
curl -s 'http://localhost:8428/api/v1/label/__name__/values' | grep -E 'mvno_|rtpengine|fivegs|vm_app|ran_ue' | head -40
curl -s 'http://localhost:8428/api/v1/query?query=mvno_sms_requests_total' | head -c 400
```

Open `http://localhost:3000` → **MVP Unified NOC** dashboard (admin/admin).
Expected: `count(up)` reflects all **9** vmagent targets UP; dashboards render
panels with non-zero values; Grafana datasource `VictoriaMetrics`
(uid `victoriametrics`) → `victoria-metrics:8428`.

---

## Flow K — AI Spam Block (deterministic E2E-BLOCK)

**Goal**: prove the SMS interception core **drops** a spam SMS end-to-end: the
inline AI-filter mock (config-only rule in `docker-compose.yml`) returns
`allow:false` whenever the classification payload contains the marker `E2E-BLOCK` —
Kamailio then replies `403 SMS Intercepted / Blocked` and the message is never
delivered.

**Verify in**: T0/T1, the sender terminal log, and the API blocked counter.

Raw (canonical — Section 0.7: `nc` + digest, body `E2E-BLOCK ...` → `403` + counter
increment + `SMS BLOCKED BY MVNO INTERCEPTION CORE` in Kamailio), or scripted:

### Terminal T5a — receiver (dedicated container, 5G→5G leg)

```bash
podman run -d --name ims-rx56 --network mvno_mvno_net --ip 10.89.0.56 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode recv --msisdn 15557654321 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.56
```

### Terminal T5b — sender sends a spam MESSAGE

```bash
podman run -d --name ims-tx55 --network mvno_mvno_net --ip 10.89.0.55 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15557654321 --body "E2E-BLOCK urgent offer!!" \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.55
podman logs ims-tx55     # expect: "MESSAGE not accepted: 403 Forbidden"
```

**Expected**:
- Kamailio logs the block: `podman logs mvno-kamailio --since 2m | grep "SMS BLOCKED BY MVNO INTERCEPTION CORE"`.
- The API blocked counter increments:
  `curl -s http://localhost:8080/actuator/prometheus | grep ^mvno_sms_blocked_total`
- The receiver **never** receives the message (its log has no `E2E-BLOCK` line).
- No `[RELAY]`/SMPP traffic in T0 — the message is dropped before relay.

---

## Flow L — Automated E2E Gate (e2e_runbook.sh)

**Goal**: run the full 5-cell end-to-end matrix as a single self-verifying gate —
the same script used to certify Goal 7. It asserts on **live metrics**, not logs.

```bash
./scripts/testing/e2e_runbook.sh
echo "exit=$?"    # 0 = ALL CELLS PASS
```

**Expected output** (all green, two consecutive runs verified 2026-08-03):

```
Cell 1: 2G->2G  ... ok  (bridge counters unchanged)
Cell 2: 2G->5G  ... ok  (bridge 2g5g +1; terminal received)
Cell 3: 5G->2G  ... ok  (bridge 5g2g +1; MS1 sms.txt has the body)
Cell 4: 5G->5G  ... ok  (bridge counters untouched)
Cell 5: AI-BLOCK ... ok (blocked counter +1; sender saw 403; kamailio logged block)
==== E2E RUNBOOK: ALL CELLS PASS (7 ok) ====   exit=0
```

The script spins up its own dedicated terminal containers (10.89.0.54/55/56) and
cleans them up; any failure exits non-zero at the summary.

> **Ordering caveat**: if the demo gate ran first and left pending rows in
> `smsc.db`, the bridge retries them at poll speed and can break e2e cell 4's
> "no challenge" assertion — drain first:
> `sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"`.

---

## Flow M — Call Recording → ASR Transcription (RTPEngine pcap → WAV → Vosk)

**Goal**: take the call you just made in Flow E, extract the G.711 audio from
RTPEngine's pcap recording, and get a **Vosk transcription of the recorded call**.

Every call is recorded to `state/spool/pcaps/call-*.pcap` by RTPEngine
(`recording-method=pcap`, `recording-format=eth` — the mr9.4 image cannot write WAV
directly, see `configs/rtpengine/rtpengine.conf`). The Vosk ASR watcher polls
`state/spool/` every ~3 s and writes the transcript to `state/spool/archived/`.

### Terminal T6b — extract the latest recorded call

Raw (canonical — Section 0.5: `tshark -d udp.port==<even-dst>,rtp` +
`rtp.p_type==0` + `xxd -r -p` + `ffmpeg -f mulaw`), or scripted:

```bash
# 1) Find the newest recording (also in state/spool/metadata/):
ls -t state/spool/pcaps/ | head -1

# 2) Extract it to the Vosk spool root (watcher polls this directory):
python3 scripts/testing/pcap_to_wav.py $(ls -t state/spool/pcaps/*.pcap | head -1)
cp $(ls -t state/spool/pcaps/*.wav | head -1) state/spool/
```

**Expected**:

```
[+] WAV extracted: state/spool/pcaps/call-1785779063@mvno-xxxxxxxx.pcap.wav (10.9s audio)
```

### Terminal T6c — read the transcript

```bash
sleep 5
cat state/spool/archived/call-*.txt   # newest = the call you just made
```

**Expected**: a JSON transcript line per recording. The certified 2026-08-03 run
(synthetic 440 Hz tone) produced `{"text": ""}` — correct for a tone. For **real
speech**, expect the words: Section 0.6's baresip speech phrase transcribes to
`{"text": "you have won a prime target now"}` (2026-08-06).

> **Sample-rate caveat**: `pcap_to_wav.py` writes 8 kHz (PCMU native). The Vosk model
> is 16 kHz, so an 8 kHz file transcribes reliably but with reduced fidelity — if a
> transcript comes back empty for real speech, upsample first:
> `ffmpeg -i state/spool/call-*.wav -ar 16000 state/spool/call-16k.wav`.
> (The Section 0.5 raw pipeline already outputs 16 kHz.)

### Terminal T6d — post-call AI transcript verdict

After ASR, `NativeVoskService` routes the transcript to the AI filter as a
`TRANSCRIPT` event (`/api/v1/classify`) and records the verdict. Verify in the
`mvno-api` logs and metrics:

```bash
podman logs mvno-api 2>&1 | grep "AI transcript verdict" | tail -3
curl -s 'http://localhost:8428/api/v1/query' --data-urlencode \
  'query=mvno_vosk_classified_total' | head -c 400
```

**Expected**: a log line per recording like
`AI transcript verdict [call-1785097956%40127.0.0.1-<hash>]: allow=true, reason='Clean content'`
(and `allow=false` / `"Spam (E2E deterministic block)"` when the recording is an
`E2E-BLOCK`-bearing spam call), plus a non-zero `mvno_vosk_classified_total`.
A filtered verdict also increments `mvno_vosk_blocked_total`. For speech matching
the keyword rule (`won|prize|claim|free|urgent|account|blocked|confirm`) the
verdict is `allow=false, reason='Spam (phishing phrase detected)'` — see Section 0.6.

---

## Flow N — Automated Demo Gate (demo_runbook.sh)

**Goal**: run the 13-check graduation demo as a single self-verifying gate — the same
script used to certify the project demo (13/13 passed, two consecutive runs
2026-08-03). It covers far more than the e2e gate: health probes, 5G UE registration,
Vector log aggregation, balance query, zero-trust auth (401 without `X-API-Key`,
check 4b), authorized VoIP call with **full RTP media relayed through RTPEngine**
(check 5, `rtpengine_bytes_total` delta) + the **recording pipeline** (check 5c:
pcap → WAV → Vosk transcript), 5G user-plane SIP, zero-balance call block
(407 → 403), EIR SIM-swap fraud block, 5G SMS interception, Vosk ASR, **post-call
scam verdict** (check 9b: speech → Vosk → TRANSCRIPT → `mvno_vosk_blocked_total`
increment), SMPP PDU bind + **SUBMIT_SM** (checks 10/10b), VictoriaMetrics PromQL,
Grafana NOC, and overall readiness.

```bash
./scripts/testing/demo_runbook.sh
echo "exit=$?"    # 0 = ALL 13 CHECKS PASS
```

**Expected output** (final line):

```
  🎉 ALL 13 DEMO ITEMS PASSED — GRADUATION PROJECT DEMO READY!
```

> The 5G-path check (`[5b]`) runs `sip_traffic_sim.py` inside `mvno-ueransim-ue-1`
> over the real 5G user plane and asserts the UPF `ogstun` TX byte counter moves
> (+2684 bytes) — proof SIP traversed GTP-U, not the test network.

---

## Flow O — Failure-Path & Resilience Checks

**Goal**: watch the core fail safely: unregistered destinations, bounded retries, and
spam rejection — without breaking the happy paths.

### O.1 — SMS to an unregistered 5G subscriber (Kamailio 404)

Sender: run `ims-tx` as in Flow D but with a **peer that is NOT registered**
(no UAS/recv terminal running, e.g. `15559998888` after Flow E cleanup):

```bash
podman run -d --name ims-tx404 --network mvno_mvno_net --ip 10.89.0.55 \
  -v $PWD/scripts/testing:/scripts:z python:3.11-alpine \
  python3 /scripts/ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15559998888 --body "who is there" \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.55
podman logs ims-tx404
```

**Expected**: `MESSAGE not accepted: 404 Not Found` — the bridge never sees the row,
and the 2G→5G variant (inject to the same unregistered 5G number) gets bounded retries
instead of an infinite loop.

### O.2 — Bounded retry on a failing 2G→5G row (MAX_ATTEMPTS=5)

With the 5G recipient still unregistered, inject a 2G→5G row and watch T3:

```bash
python3 scripts/testing/inject_smsc_row.py 15554443322 15559998888 "will retry then drop"
watch -n2 'sqlite3 state/hlr/smsc.db "SELECT id,src_addr,dest_addr,text,sent,deliver_attempts FROM SMS;"'
```

**Expected**: `deliver_attempts` climbs to `5` (bridge gets `404` each poll) then the
row leaves the pending set — bounded, no infinite spin (Troubleshooting #2/#3).

### O.3 — Spam SMS is dropped before relay (already Flow K, quick re-run)

```bash
python3 scripts/testing/inject_smsc_row.py 15554443322 15551234567 "E2E-BLOCK offer!!"
podman logs mvno-kamailio --since 2m | grep "SMS BLOCKED BY MVNO INTERCEPTION CORE"
```

**Expected**: one `SMS BLOCKED...` line; the row is never delivered; the API counter
`mvno_sms_blocked_total` (actuator) increments.

---

## Troubleshooting & Known Quirks

### 1. Kamailio relay loops / 408s with a co-located receiver
**Symptom**: 5G→2G SMS fails or loops when the receiver runs **inside**
`mvno-ip-sm-gw` (10.89.0.53).
**Root cause**: source-IP ambiguity — Kamailio sees the bridge's IP and confuses
the receiver and the relay, so routing/acks fail.
**Fix**: always run the UE *receiver* in a **dedicated container with its own IP**
(e.g. `10.89.0.60`) on `mvno_net`. This is a **test-harness** concern, not a
bridge bug.

### 2. Bridge no longer spins on a failed 2G→5G delivery — bounded retry
**Symptom**: previously a failed delivery retried at full speed forever.
**Root cause**: `mark_attempt()` was never invoked on failure.
**Fix (applied)**: the bridge now calls `mark_attempt()` on a failed send, bounding
retries to `MAX_ATTEMPTS=5`; the row drops out of the pending set and the sender
is not hammered.

### 3. Pike `429 Too Many Requests` flood
**Symptom**: Kamailio returns 429 after a burst of MESSAGEs.
**Root cause**: the bridge served the SIP listener with a tight `0.2s` timeout when
a row existed, re-attempting deliveries in a spin and tripping Kamailio's
anti-flood module.
**Fix (applied)**: the listener now always uses `POLL_INTERVAL` regardless of
pending rows; backoff is handled via `MAX_ATTEMPTS`.

### 4. 5G sender previously reported "no resp" for 5G→2G SMS (FIXED)
**Symptom (historical)**: the sender terminal got no final response; the bridge
relayed the SMS **~9 times** (duplicate deliveries to the 2G handset).
**Root cause**: `reply_ok()` in `scripts/ip_sm_gw.py` re-prefixed the already-whole
`Via:` header lines, emitting an invalid `Via: Via: ...` in the 200 OK — Kamailio's
tm never matched the transaction branch and retransmitted forever.
**Fix (applied 2026-08-03)**: strip the `Via:` prefix before re-emitting
(`ln.strip().split(":", 1)[1].strip()`). Verified: exactly **one** `[RELAY]` per
SMS, sender receives its final `200 OK`, MS1 `sms.txt` has one copy. See
`docs/ISSUES.md` for the full RCA.

### 5. A 2G→5G row never gets marked `sent`
Check in T3: `deliver_attempts` should climb to `MAX_ATTEMPTS` and stop. If the
destination 5G terminal is **not registered** with Kamailio, the bridge gets `404` and
retries (bounded). Register the terminal first (`--mode recv` registers automatically).

### 6. AI filter mock always allows (blocked counter stuck at 0) — FIXED
**Symptom (historical)**: `POST /api/v1/intercept/sms` returned
`{"allow":true,"reason":"Clean content"}` even for `E2E-BLOCK` content, and
`mvno_sms_blocked_total` never incremented.
**Root cause**: Spring's `RestClient` sends the classify request with
`Transfer-Encoding: chunked` (no `Content-Length`); the inline mock only read the
`Content-Length` body → always saw an empty body → always allowed.
**Fix (applied 2026-08-03)**: the mock in `docker-compose.yml` now parses chunked
bodies. Verified: `E2E-BLOCK` → `{"allow":false,...}` + counter increments. A real
FastAPI classifier is unaffected (chunked is handled natively). See
`docs/ISSUES.md` for the full RCA.

### 7. Voice call rings but dies with 408 / media never flows (FIXED)
**Symptom (historical)**: the callee registered and the INVITE was accepted, but
Kamailio forwarded it to a dead port (`Contact: sip:...@10.89.0.58:42461`) and the
call never completed. Also: caller's ACK/BYE looped back into Kamailio because they
targeted `sip:...@localhost:5060` instead of the 200 OK Contact.
**Root cause**: the simulator registered from an **unbound socket** — its source port
was ephemeral and died with the process — and `fix_nated_contact()` rewrote the stored
contact to that dead port. `t_relay()` forwards silently.
**Fix (applied 2026-08-03)**: `register_subscriber()` now binds `(bind_ip,
listen_port)` and keeps the socket alive; the UAS replies echo `Record-Route`; ACK/BYE
target the 200 OK Contact. Always run each role in its own container with
`--bind-ip <container-ip> --listen-port <port>` (see Flow E). Full RCA in
`docs/ISSUES.md` Section 8.27.

### 8. Stale contacts linger in `kamailio.db` after test rigs die
**Symptom**: `state/kamailio/kamailio.db` (usrloc, db_mode=2) can hold old
ephemeral-port contacts next to the live one until their `Expires` elapses.
**Effect**: harmless in practice — `t_relay()` forks to **all** contacts, and the
live one still receives the INVITE. Rows self-expire (`Expires: 3600`); no action
needed.
**Caveat**: the file is owned by the container user `101000`; **hand-editing it
from the host (or deleting the `-wal`/`-shm` sidecars mid-run) can break
Kamailio's authentication silently** — if REGISTERs stop being answered after DB
surgery, `podman restart mvno-kamailio` restores service (verified 2026-08-06).

### 9. baresip specifics (verified 2026-08-06)
- **`-d` daemonize breaks registration** — REGISTERs go unanswered. Run
  backgrounded without `-d`: `podman run ... baresip -f /cfg -s -T`.
- **`ua: no laddr for 127.0.0.1` (EINVAL 22)** when dialing a loopback/container
  IP from the host — baresip finds no local interface for the target subnet
  (the rootless host has no address on `mvno_mvno_net`). **Always run baresip in
  a container on `mvno_mvno_net`** with an explicit `--ip`.
- **stdin/`-e` command piping fails** (`fd_listen err: fd=0`); drive it over the
  **ctrl_tcp console** (`module_app ctrl_tcp.so`, listens 127.0.0.1:4444) with
  netstring framing `<len>:<json>,` — dial = `{"command":"dial","params":"sip:...@10.89.0.23:5060"}`.
  The `params` key is required (`uri` is ignored: "can't find a URI to dial to").
- **`module_app account.so`** (and `menu.so` for the dial command) — these are
  application modules, not plain `module` entries.
- **No outgoing MESSAGE in v4.6.0's menu.so** — baresip receives SMS fine
  (console prints the body) but cannot *send* one; use the raw `nc`+digest
  flow of Section 0.6c for sending.
- **Audio source for the speech leg**: `audio_source aufile,/media/speech8k.wav`
  in the rx config; the WAV must be 8 kHz mono s16le. Rebuild the container to
  pick up config/WAV changes.
- **Cosmetic stderr noise**: inside a container with a closed stdin, baresip
  prints `epoll_ctl: EPOLL_CTL_ADD: fd=0 (Operation not permitted)` +
  `fd_listen err: fd=0` once at startup — harmless, ignore it (the stdio
  console just can't bind fd 0).

### 10. Only MS1 (`15554443322`) logs receipts in `sms.txt`
**Symptom**: an SMS addressed to `15557778888` (MS2) is accepted by the SMSC
(`Going to send a MT SMS`) but never appears in `/root/.osmocom/bb/sms.txt`.
**Root cause**: the `mvno-2g-ms` container runs **one** `mobile` app serving
MS1 (`IMSI 001010000000004`); MS2 exists in the HLR but has no handset.
**Fix**: use `15554443322` as the 2G recipient for any receipt check.

### 11. tshark RTP extraction gotchas
- The payload-type filter field is **`rtp.p_type`** — `rtp.pt` is **not valid**
  and yields an empty result (field/decoder error swallowed by `2>/dev/null`).
- The `-d udp.port==<port>,rtp` override must name the **rtpengine-side
  destination port**; overriding the client source port is a silent no-op.
- RTP media ports are even; RTCP = odd (+1) — filter
  `udp.dstport%2==0` to skip RTCP before picking the speech leg.

### 12. `nc -u` hangs waiting after the response
**Symptom**: `nc -u ...` never returns after Kamailio's 407/200 response.
**Cause**: the UDP socket stays open. **Fix**: wrap in `timeout 5 nc -u ...`
(and feed the request from a file/heredoc, not an interactive terminal).

### 13. Pending SMS rows break the e2e gate's cell 4
**Symptom**: `demo_runbook.sh` finishes, then `e2e_runbook.sh` cell 4 fails with
"no nonce challenge" / `rx56 hits=0`.
**Root cause**: demo check 10b leaves a pending 2G→5G row in `smsc.db`; the bridge
retries it at poll speed during e2e cell 4, and the relay traffic trips the
"bridge must stay out of 5G→5G" assertion.
**Fix**: before running gates, drain pending rows:
`sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;"`
(rows at `deliver_attempts=5` are inert and safe to leave).

---

*End of manual testing guide. All flows verified against the running stack
(2026-08-06; e2e_runbook.sh 7/7 and demo_runbook.sh 13/13 certified green, two
consecutive runs each; Section 0 from-zero demo fully verified with baresip voice,
tshark→WAV→Vosk spam verdict, raw SMPP/sqlite3/nc+digest SMS paths, and the
E2E-BLOCK 403 path).*
