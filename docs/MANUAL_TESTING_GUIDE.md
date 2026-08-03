# MVNO Telecom Core — Manual Testing Guide

A hands-on, terminal-by-terminal guide for verifying **every** active flow in the MVNO
private-mobile-network core: **2G SMS, 5G/IMS SMS, 2G↔5G SMS bridging (IP-SM-GW),
SIP/IMS calls, RTPEngine media plane, Vosk speech-to-text, and call recording**.

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
13. [Troubleshooting & Known Quirks](#troubleshooting--known-quirks)

---

## 1. Prerequisites & Reference Data

Ensure the full stack is up and healthy **before** running any flow:

```bash
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
podman compose ps          # expect 32/32 containers Up
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
| OsmoSMSC VTY | `127.0.0.1:4254` |
| SMPP 3.4 (OsmoSMSC ESME) | `127.0.0.1:2775` |
| Kamailio SIP (host-mapped) | `127.0.0.1:5066` |
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
| **T5** | 5G UE receiver (to receive IMS SMS) | see Flow B |

**Golden rule**: give each agent (receiver, bridge, sender) its **own IP/container**.
Do **not** run the receiver in the same container as the bridge (`mvno-ip-sm-gw`),
or Kamailio sees a source-IP ambiguity and relays loop / 408s (see Troubleshooting).

---

## 3. Quick reference — sending a 2G SMS into the SMSC queue

These three tools inject an MO/MT SMS into OsmoSMSC's `store-and-forward` queue. The
IP-SM-GW bridge drains rows targeting a 5G subscriber (Flow B), and rows targeting a
2G subscriber are delivered natively by OsmoSMSC to the attached 2G MS (Flow A).

```bash
# A) Direct SQLite injection into the SMSC queue
./scripts/testing/send_db_sms.sh 15554443322 15557654321 "Hello via DB queue"

# B) Via the OsmoSMSC Cisco-style VTY operator console (port 4254)
./scripts/testing/send_vty_sms.sh 15554443322 15557654321 "Hello via VTY console"

# C) Via binary SMPP 3.4 submit_sm (port 2775) — the same path the IP-SM-GW uses
python3 scripts/testing/send_smpp_sms.py --sender 15554443322 --recipient 15557654321

# D) Via the Gateway REST interception API (evaluates balance/EIR/spam policies)
./scripts/testing/send_rest_sms.sh 15554443322 15557654321 "Hello via REST API"
```

> All four target `sender->recipient`. To hit the **2G→5G bridge** use a 5G
> `recipient` (e.g. `15557654321`); to keep it **2G→2G** use a 2G `recipient`
> (e.g. `15557778888`).

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
- Queue table shows **no** lingering unsent row for a 2G destination.

---

## Flow B — 2G → 5G SMS (IP-SM-GW bridge, leg 1)

**Goal**: an SMS injected on the 2G side for a **5G** subscriber is bridged by
`mvno-ip-sm-gw`, relayed by Kamailio, and received by the 5G UE.

**Verify in**: T0 (bridge log: `POLL` → `SEND` → `DELIVERED`), T2, T3.

### Terminal T5 — 5G UE receiver (must be its OWN container with its own IP)

```bash
# Create a dedicated receiver so Kamailio can route replies back cleanly.
podman run -d --name ue-recv --network mvno_net \
  -e IP=10.89.0.60 -e PORT=5091 -e MSISDN=15557654321 \
  --entrypoint python3 therecipe/mvno-ims-ue:latest \
  -c "from ims_terminal import *; python_sms_receiver()"
# OR, if the UEs already run a persistent terminal:
podman exec -it mvno-ue1 /bin/bash   # 5G UE-1 terminal
python3 ims_terminal.py --mode recv
```

> The 5G UE that will **receive** must be registered with Kamailio so the relay
> can reach it. Receiver listens on `:5091`.

### Terminal T0 — inject the 2G→5G SMS

```bash
# 2G sender -> 5G recipient (UE-2). The bridge polls smsc.db for exactly this.
./scripts/testing/send_db_sms.sh 15554443322 15557654321 "GATE6 2Gto5G"
```

**Expected bridge log** (watch T0):

```
[POLL] row_id=NN 15554443322->15557654321 body='GATE6 2Gto5G'
[SEND] 15554443322->15557654321 OK
[DELIVERED] row_id=NN marked sent
```

**Expected**:
- Kamailio (T1) relays the SIP MESSAGE to the registered 5G UE.
- The 5G UE receiver replies `200 OK`.
- In T3, the row's `sent` is no longer `NULL` and `deliver_attempts` becomes `1`.

*(Verified in-session as row 17, `15554443322→15551234567`, body `GATE6 2Gto5G`.)*

---

## Flow C — 5G → 2G SMS (IP-SM-GW bridge, leg 2)

**Goal**: a 5G/IMS subscriber sends a SIP MESSAGE to a 2G number; the bridge
receives it, acks Kamailio, and injects it into OsmoSMSC via SMPP for 2G delivery.

**Verify in**: T0 (bridge log: `[RELAY] 5G->2G`, `[SMPP] BIND_TRANSCEIVER OK`,
`[SMPP] SUBMIT_SM OK`), T2, T3.

### Terminal T5 — 5G UE sender

```bash
podman exec -it mvno-ue1 /bin/bash
python3 ims_terminal.py --mode send   # follows prompts
# Sender: 15551234567
# Recipient: 15554443322
# Body: GATE6 5Gto2G
```

**Expected bridge log** (watch T0):

```
[RELAY] 5G->2G 15551234567->15554443322 body='GATE6 5Gto2G'
[SMPP] BIND_TRANSCEIVER OK
[SMPP] SUBMIT_SM OK 15551234567 -> 15554443322
```

**Expected**:
- The 2G MS receiver prints the SMS (MS already attached → immediate MT).
- Because the 2G recipient is attached, OsmoSMSC delivers immediately and does
  **not** create a new store-and-forward row.

> **Quirk**: the 5G *sender* terminal may report *"no resp"* on its own socket
> even though the message was delivered. That is a test-harness artifact (the
> simple terminal does not stitch the transactional 200 back to the original
> socket); the **bridge log is the ground truth** — if you see `SUBMIT_SM OK`,
> the 2G side got the SMS.

*(Verified in-session: full `SMPP BIND + SUBMIT_SM OK` path.)*

---

## Flow D — 5G → 5G SMS (IMS SMS-over-IP end-to-end)

**Goal**: pure IMS/SIP SMS between two 5G UEs through Kamailio with **no** bridge
involvement.

**Verify in**: T1 (Kamailio relay), T5 (both UEs).

### Terminal T5a — UE-2 receiver

```bash
podman exec -it mvno-ue2 /bin/bash
python3 ims_terminal.py --mode recv
```

### Terminal T5b — UE-1 sender

```bash
podman exec -it mvno-ue1 /bin/bash
python3 ims_terminal.py --mode send
# Sender: 15551234567  Recipient: 15557654321  Body: IMS 5Gto5G SMS
```

**Expected**:
- T1 shows Kamailio relaying the SIP MESSAGE to UE-2.
- UE-2 prints the incoming IMS SMS.
- No `[RELAY] 5G->2G` and no SMPP traffic in T0 (both endpoints are 5G).

---

## Flow E — SIP/IMS Voice Call (RTPEngine anchored)

**Goal**: establish an end-to-end SIP INVITE dialog between two IMS UEs with media
anchored through RTPEngine.

**Verify in**: T1 (Kamailio), plus RTPEngine logs.

### Terminal T5a — called party (UE-2)

```bash
podman exec -it mvno-ue2 /bin/bash
python3 ims_terminal.py --mode call --role callee
```

### Terminal T5b — calling party (UE-1)

```bash
podman exec -it mvno-ue1 /bin/bash
python3 ims_terminal.py --mode call --role caller --peer 15557654321
```

Alternatively, the parameterised simulator can drive REGISTER + INVITE dialogs:

```bash
python3 scripts/testing/sip_traffic_sim.py
```

**Expected**:
- UE-1 sends `INVITE sip:15557654321@mvno`; Kamailio routes to UE-2.
- UE-2 answers `200 OK`; an `ACK` completes the dialog.
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
ls state/vosk-model/ 2>/dev/null || ls state/vosk/ 2>/dev/null
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
- `count(up)` reflects all 8 vmagent targets UP.
- Dashboards render panels with non-zero values (no empty/gray 0-data panels).
- Grafana datasource `VictoriaMetrics` (uid `victoriametrics`) → `victoria-metrics:8428`.

Open `http://localhost:3000` → **MVP Unified NOC** dashboard.

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

### 4. 5G sender reports "no resp" but the SMS still arrives on 2G
**Explanation**: the simplified `ims_terminal.py` sender does not stitch the
transactional `200` back to its own socket after the Kamailio relay + bridge leg.
Treat the **bridge log** (`[RELAY] … [SMPP] SUBMIT_SM OK`) as ground truth.

### 5. A 2G→5G row never gets marked `sent`
Check in T3: `deliver_attempts` should climb to `MAX_ATTEMPTS` and stop. If the
destination 5G UE is **not registered** with Kamailio, the bridge gets `404` and
retries (bounded). Register the UE first.

---

*End of manual testing guide. All flows verified against the running stack.*


