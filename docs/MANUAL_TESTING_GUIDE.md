# MVNO Telecom Core — Manual Testing Guide

A hands-on, terminal-by-terminal guide for verifying **every** active flow in the MVNO
private-mobile-network core: **2G SMS, 5G/IMS SMS, 2G↔5G SMS bridging (IP-SM-GW),
SIP/IMS calls, RTPEngine media plane, Vosk speech-to-text, call recording, and the
deterministic AI spam-block path**.

All commands below were **empirically verified** against the running stack
(`podman compose up`). Each flow is shown as a set of commands you paste into
**separate terminal windows** so you can watch each leg in real time.

---

## Table of Contents

1. [Prerequisites & Reference Data](#1-prerequisites--reference-data)
2. [Terminal Layout (suggested)](#2-terminal-layout-suggested)
3. [Flow A — 2G → 2G SMS (SMSC store-and-forward)](#flow-a--2g--2g-sms-smsc-store-and-forward)
4. [Flow B — 2G → 5G SMS (IP-SM-GW bridge, leg 1)](#flow-b--2g--5g-sms-ip-sm-gw-bridge-leg-1)
5. [Flow C — 5G → 2G SMS (IP-SM-GW bridge, leg 2)](#flow-c--5g--2g-sms-ip-sm-gw-bridge-leg-2)
6. [Flow D — 5G → 5G SMS (IMS SMS-over-IP end-to-end)](#flow-d--5g--5g-sms-ims-sms-over-ip-end-to-end)
7. [Flow E — SIP/IMS Voice Call (RTPEngine anchored)](#flow-e--sipims-voice-call-rtpengine-anchored)
8. [Flow F — RTPEngine Media Plane metrics](#flow-f--rtpengine-media-plane-metrics)
9. [Flow G — Vosk Speech-to-Text ASR](#flow-g--vosk-speech-to-text-asr)
10. [Flow H — Live Microphone Recording + Transcription](#flow-h--live-microphone-recording--transcription)
11. [Flow I — Interception Gateway REST API](#flow-i--interception-gateway-rest-api)
12. [Flow J — Grafana NOC & VictoriaMetrics telemetry](#flow-j--grafana-noc--victoriametrics-telemetry)
13. [Flow K — AI Spam Block (deterministic E2E-BLOCK)](#flow-k--ai-spam-block-deterministic-e2e-block)
14. [Flow L — Automated E2E Gate (e2e_runbook.sh)](#flow-l--automated-e2e-gate-e2e_runbooksh)
15. [Troubleshooting & Known Quirks](#troubleshooting--known-quirks)

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

### Key services & ports (host-facing)

| Service | Host endpoint |
| :--- | :--- |
| Interception Gateway (Spring Boot) | `http://localhost:8080` |
| AI Spam Filter (inline mock, E2E-BLOCK rule) | `http://localhost:8008` |
| OsmoSMSC VTY | `127.0.0.1:4254` |
| SMPP 3.4 (OsmoSMSC ESME) | `127.0.0.1:2775` |
| Kamailio SIP (host-mapped) | `127.0.0.1:5066` |
| IP-SM-GW bridge metrics | `http://localhost:9100/metrics` |
| VictoriaMetrics PromQL | `http://localhost:8428` |
| Grafana | `http://localhost:3000` (admin/admin) |

---

## 2. Terminal Layout (suggested)

Open these terminal tabs and keep them running *before* you start a flow:

| Tab | Purpose | Command to start in that tab |
| :--- | :--- | :--- |
| **T0** | IP-SM-GW bridge logs | `podman logs -f mvno-ip-sm-gw` |
| **T1** | Kamailio (syslog) | `podman logs -f mvno-kamailio 2>&1 \| grep -iE 'message\|relay\|sms'` |
| **T2** | OsmoSMSC / MSC logs | `podman logs -f mvno-osmosmsc 2>&1 \| tail -f` |
| **T3** | SMS queue state | `watch -n2 "python3 -c \"import sqlite3;c=sqlite3.connect('state/hlr/smsc.db');c.row_factory=sqlite3.Row;print(list(c.execute('SELECT id,src_addr,dest_addr,text,sent,deliver_attempts FROM SMS')))\""` |
| **T4** | 2G MS receiver (to receive SMS) | see Flow A |
| **T5** | 5G/IMS terminal (receiver or sender) | see Flow B/C/D |

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

Free static IPs reserved for this: **10.89.0.54 / 10.89.0.55 / 10.89.0.56**.
All SIP digest passwords default to `testpass`; registered subscribers live in
Kamailio's `subscriber` table.

> In-UE alternative (uses the real 5G SA user plane): `podman exec -it
> mvno-ueransim-ue-1 ...` — see the note under Flow B. Requires the
> `ip route replace 10.89.0.23/32 dev uesimtun0` inside the UE container.

**Golden rule**: give each agent (receiver, bridge, sender) its **own IP/container**.
Do **not** run the receiver in the same container as the bridge (`mvno-ip-sm-gw`),
or Kamailio sees a source-IP ambiguity and relays loop / 408s (see Troubleshooting).

---

## 3. Quick reference — sending a 2G SMS into the SMSC queue

These tools inject an MO/MT SMS into OsmoSMSC's `store-and-forward` queue. The
IP-SM-GW bridge drains rows targeting a 5G subscriber (Flow B), and rows targeting a
2G subscriber are delivered natively by OsmoSMSC to the attached 2G MS (Flow A).

```bash
# A) Direct SQLite injection into the SMSC queue — THE RELIABLE 2G->5G row driver
#    (writes the bridge's real polled SMS table: state/hlr/smsc.db, deliver_attempts=0)
python3 scripts/testing/inject_smsc_row.py 15554443322 15551234567 "Hello via DB queue"

# B) Via binary SMPP 3.4 submit_sm (port 2775) — the same path the IP-SM-GW uses
python3 scripts/testing/send_smpp_sms.py --sender 15554443322 --recipient 15557654321

# C) Via the Gateway REST interception API (evaluates balance/EIR/spam policies)
./scripts/testing/send_rest_sms.sh 15554443322 15557654321 "Hello via REST API"
```

> **Do NOT use `send_db_sms.sh`** (invented `sms`/`sender_id` schema writing to a
> different DB than the bridge polls — the row is never seen) and prefer
> `inject_smsc_row.py` over `send_vty_sms.sh` (VTY driver is fragile/quirky).
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

Any of the send tools in §3 with a **2G recipient**. Native delivery needs the
recipient 2G MS attached to the VLR:

```bash
./scripts/testing/send_vty_sms.sh 15554443322 15557778888 "2Gto2G Native SMS"
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
# 2G sender -> 5G recipient (UE-1 MSISDN). The bridge polls smsc.db for exactly this.
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

### Terminal T5 — 5G sender (dedicated container)

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

## Flow E — SIP/IMS Voice Call (RTPEngine anchored)

**Goal**: establish an end-to-end SIP INVITE dialog between two IMS UEs with media
anchored through RTPEngine.

**Verify in**: T1 (Kamailio), plus RTPEngine logs.

The parameterised simulator drives REGISTER + INVITE dialogs (it registers the
callee itself):

```bash
# From the host (host-mapped 5066) or from a UE container (10.89.0.23:5060):
python3 scripts/testing/sip_traffic_sim.py --host 127.0.0.1 --port 5066 \
  --caller 15551234567 --callee 15557654321
```

**Expected**:
- The caller sends `INVITE sip:15557654321@...`; Kamailio routes to the callee.
- The callee answers `200 OK`; an `ACK` completes the dialog.
- RTPEngine logs show a session being created for the media leg.
- Grafana's `rtpengine_sessions_total` increments.

---

## Flow F — RTPEngine Media Plane metrics

**Goal**: observe live RTPEngine counters feeding VictoriaMetrics.

```bash
# Direct metric (if RTPEngine exposes a metrics endpoint; else via Grafana)
curl -s http://localhost:9464/metrics | grep -i rtpengine | head
```

**Expected (Grafana)**: the Media Plane row shows `rtpengine_sessions_total`
and packet/byte counters incrementing while calls are active.

> The single authoritative RTPEngine metric is **`rtpengine_sessions_total`**.
> The older names `rtpengine_active_calls` / `rtpengine_sessions_total_count`
> **do not exist** in the current scrape set and show as 0-data panels —
> the dashboards have been corrected to use the real metric.

---

## Flow G — Vosk Speech-to-Text ASR

**Goal**: run the **native Vosk ASR engine** end-to-end on an audio sample stored in
the spool, then read its transcription.

Make sure the Vosk ASR container/service is up and a model exists:

```bash
podman compose ps | grep -i vosk
ls vendor/vosk/vosk-model-small-en-us-0.15/   # mounted model (ro)
```

Place a 16 kHz mono WAV in the spool and let the ASR watcher transcribe it:

```bash
# Drop an audio file into the watched spool directory:
cp sample.wav state/spool/
# The ASR background watcher writes state/spool/archived/<name>.txt
sleep 5
cat state/spool/archived/sample.txt
```

**Expected**: a plain-text transcription of the spoken words.

---

## Flow H — Live Microphone Recording + Transcription

**Goal**: record your laptop microphone in real time and have Vosk transcribe it.

```bash
# Record 5 seconds of mic audio, save as 16kHz mono WAV, then show ASR result.
./scripts/testing/record_mic_call.sh 5
```

**Expected output**:

```
🎙️ Live Laptop Microphone Speech-to-Text Recorder
  Duration:  5 seconds
✓ Microphone recording captured successfully: state/spool/mic_call_*.wav
🎉 Vosk ASR Live Transcription Result (state/spool/archived/mic_call_*.txt):
  <your transcribed words>
```

The script auto-falls back through `ffmpeg -f pulse` → `ffmpeg -f alsa` →
`arecord`, so it works on PulseAudio, ALSA and PipeWire hosts.

---

## Flow I — Interception Gateway REST API

**Goal**: verify the Spring Boot gateway's SMS interception policy (balance/EIR /
AI spam filter).

```bash
./scripts/testing/send_rest_sms.sh 15551234567 15557654321 "Clean SMS"
```

**Expected**:

```json
{"allow": true}
```

The API is reachable at `http://localhost:8080/api/v1/intercept/sms` with header
`X-API-Key: mvno-demo-key-2026`. Cross-check in Grafana:
`mvno_sms_requests_total` increments.

Direct content-classification check against the AI filter mock:

```bash
curl -s http://localhost:8008/api/v1/classify -d '{"content":"clean text"}'      # {"allow":true,...}
curl -s http://localhost:8008/api/v1/classify -d '{"content":"E2E-BLOCK x"}'     # {"allow":false,...}
```

---

## Flow J — Grafana NOC & VictoriaMetrics telemetry

**Goal**: confirm every NOC panel shows **live data** and that metrics flow.

```bash
# 1) All scrape targets UP?
curl -s 'http://localhost:8428/api/v1/label/__name__/values' | grep -E 'mvno_|rtpengine|fivegs|vm_app|ran_ue' | head -40

# 2) A key business metric still incrementing?
curl -s 'http://localhost:8428/api/v1/query?query=mvno_sms_requests_total' | head -c 400

# 3) Grafana up + dashboards present?
curl -s -u admin:admin http://localhost:3000/api/search?query=mvno | python3 -m json.tool | head -40
```

**Expected**:
- `count(up)` reflects all **9** vmagent targets UP.
- Dashboards render panels with non-zero values (no empty/gray 0-data panels).
- Grafana datasource `VictoriaMetrics` (uid `victoriametrics`) → `victoria-metrics:8428`.

Open `http://localhost:3000` → **MVP Unified NOC** dashboard.

---

## Flow K — AI Spam Block (deterministic E2E-BLOCK)

**Goal**: prove the SMS interception core **drops** a spam SMS end-to-end: the
inline AI-filter mock (config-only rule in `docker-compose.yml`) returns
`allow:false` whenever the classification payload contains the marker `E2E-BLOCK` —
Kamailio then replies `403 SMS Intercepted / Blocked` and the message is never
delivered.

**Verify in**: T0/T1, the sender terminal log, and the API blocked counter.

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

---

*End of manual testing guide. All flows verified against the running stack
(2026-08-03; e2e_runbook.sh certified green, two consecutive runs).*


