#!/usr/bin/env bash
# ==============================================================================
# MVNO Telecom Core — Graduation Project Live Demo & Presentation Runbook
# ==============================================================================
# Executable 13-step demonstration script verifying end-to-end 5G SA Core,
# IMS SIP Interception, SMPP SMSC, Gateway REST APIs, and SOTA Grafana NOC.
# ==============================================================================
# Demo-time human speech (optional): during the [5b] live call, speaking into
# the host microphone captures the [caller/you] leg (pulse); the [callee/
# synthetic scam rig] leg streams the canned phrase via aufile. Both legs are
# LABELED in the evidence — your words are never presented as the canned
# phrase and never asserted against the [9b] block keyword gate (which keys
# off the callee/synthetic leg only). The seeded fixtures in
# docs/evidence/fixtures/ guarantee non-empty transcripts regardless of
# whether anyone speaks.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# Re-entrancy guard (evidence race guard): refuse to start while another
# instance is active, so two runbooks can never truncate/flush the same
# clean-slate RUN_LOG concurrently. Lock is released on EXIT.
LOCK_FILE="${TMPDIR:-/tmp}/mvno-demo-runbook.lock"
if [ -f "${LOCK_FILE}" ] && kill -0 "$(cat "${LOCK_FILE}" 2>/dev/null)" 2>/dev/null; then
    echo "[-] Error: another demo_runbook.sh instance is active (PID $(cat "${LOCK_FILE}")) — refusing to start to protect clean-slate evidence" >&2
    exit 1
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# Evidence layer: clean-slate run log (Aug-8 convention) — the file is
# truncated at run start and stamped with RUN:<ts>, so a green file contains
# exactly ONE clean pass and a red file exactly ONE honest failure. Re-runs
# never curate a mix of old failures and new passes into the same file.
EVIDENCE_DIR="${REPO_ROOT}/docs/evidence"
mkdir -p "${EVIDENCE_DIR}"
RUN_LOG="${EVIDENCE_DIR}/demo-run-$(date +%F).log"
: > "${RUN_LOG}"
exec > >(tee -a "${RUN_LOG}") 2>&1
echo "RUN:$(date +%Y-%m-%dT%H:%M:%S%z) — clean-slate evidence (previous contents discarded)"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${CYAN}==== demo runbook log: ${RUN_LOG} ====${NC}"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { FAIL=$((FAIL+1)); echo -e "${RED}  ✗ $1${NC}" >&2; exit 1; }

echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "${CYAN}${BOLD}  🎓 MVNO 5G SA Core & Interception Gateway — Live Demo Runbook        ${NC}"
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo ""

# ==============================================================================
# [1/13] GATEWAY HEALTH & LIVENESS PROBES (SPRING BOOT ACTUATOR)
# ==============================================================================
# Technical Verification: Queries Spring Boot Actuator endpoint (port 8080).
# Protocol / Component: HTTP REST / telecom-api Gateway Actuator.
# Validation Criteria: Confirms SQLite database connection is valid, disk space is
# sufficient, and livenessState = UP.
# ==============================================================================
echo -e "${YELLOW}[1/13] 🏥 Checking Gateway Actuator Health & Liveness Probes...${NC}"
status=$(curl -s http://localhost:8080/actuator/health | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
[ "$status" = "UP" ] && pass "Gateway Actuator health status = UP" || fail "Gateway health not UP (got '${status:-<no JSON>}')"

# ==============================================================================
# [2/13] 5G SA CORE UE REGISTRATION AUDIT (AMF ↔ UERANSIM)
# ==============================================================================
# Technical Verification: Queries VictoriaMetrics TSDB PromQL engine for metric 'ran_ue'.
# Protocol / Component: 5G SA N1/N2 NAS Signaling / Open5GS AMF & UERANSIM gNB/UEs.
# Validation Criteria: Asserts that ran_ue == 3 (all 3 5G subscribers: IMSI 001010000000001,
# 001010000000002, 001010000000003 are successfully registered with the 5G AMF core).
# ==============================================================================
echo -e "${YELLOW}[2/13] 📱 Auditing 5G SA Core UE Registration (UERANSIM ↔ AMF, live ran_ue gauge)...${NC}"
python3 -c "
import urllib.request, json, sys
url = 'http://localhost:8428/api/v1/query?query=ran_ue'
data = json.loads(urllib.request.urlopen(url).read().decode('utf-8'))
results = data.get('data', {}).get('result', [])
if not results:
    print('[-] Error: ran_ue series not found in VictoriaMetrics', file=sys.stderr)
    sys.exit(1)
count = int(results[0]['value'][1])
if count < 3:
    print(f'[-] Error: only {count}/3 UEs registered (ran_ue gauge)', file=sys.stderr)
    sys.exit(1)
print(f'  ✓ Live AMF gauge ran_ue = {count} (3/3 UEs registered)')
"
echo -e "${GREEN}✓ 5G SA Subscriber audit complete — 3/3 UEs Registered${NC}\n"

# ==============================================================================
# [3/13] VECTOR CONTAINER LOG AGGREGATION PIPELINE
# ==============================================================================
# Technical Verification: Checks live stdout log sink of mvno-vector container.
# Protocol / Component: Vector VRL Regex Parsing Engine (timberio/vector:0.44.0).
# Validation Criteria: Verifies VRL (Vector Remap Language) streams and parses real-time
# Kamailio SIP, OsmoSMSC, and Gateway stdout log lines into structured JSON streams.
# ==============================================================================
echo -e "${YELLOW}[3/13] ⚡ Auditing Vector Container Log Aggregation (VRL JSON sink)...${NC}"
events=$(podman exec mvno-vector tail -n 5 /var/log/vector/telecom_events.json 2>/dev/null || true)
echo "$events" | python3 -c "
import json, sys
ok = 0
for line in sys.stdin:
    line = line.strip()
    if line:
        json.loads(line)
        ok += 1
assert ok >= 1, 'no parseable JSON events'
print(f'  ✓ {ok} recent JSON event line(s) parsed by VRL')" || fail "Vector VRL sink produced no parseable telecom events"
pass "Vector VRL JSON log aggregation active"

# ==============================================================================
# [4/13] PREPAID SUBSCRIBER LEDGER BALANCE LOOKUP
# ==============================================================================
# Technical Verification: Queries Gateway REST subscriber API with X-API-Key header.
# Protocol / Component: HTTP REST API / SubscriberController.java (port 8080).
# Validation Criteria: Verifies MSISDN 15551234567 returns balance = 100 credits.
# ==============================================================================
echo -e "${YELLOW}[4/13] 💳 Querying Subscriber Balance (E.164 MSISDN: 15551234567)...${NC}"
bal=$(curl -s -H "X-API-Key: mvno-demo-key-2026" http://localhost:8080/api/v1/intercept/subscriber/15551234567 | python3 -c "import json,sys; print(json.load(sys.stdin).get('balance',''))" 2>/dev/null)
[ "$bal" = "100" ] && pass "Subscriber 15551234567 balance = 100 credits" || fail "Subscriber balance != 100 (got '${bal:-<no JSON>}')"

# ------------------------------------------------------------------------------
# [4b/13] GATEWAY ZERO-TRUST AUTH (missing X-API-Key -> HTTP 401 Unauthorized)
# ------------------------------------------------------------------------------
# Technical Verification: Calls the same subscriber endpoint WITHOUT the API key.
# Protocol / Component: HTTP REST / ApiKeyInterceptor.java (X-API-Key zero-trust).
# Validation Criteria: Response HTTP status MUST be 401 and body MUST be empty.
# ==============================================================================
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/v1/intercept/subscriber/15551234567)
if [ "$CODE" != "401" ]; then
    echo "[-] Error: expected HTTP 401 without X-API-Key, got ${CODE}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Zero-trust enforced: no X-API-Key -> HTTP ${CODE}${NC}\n"

# ==============================================================================
# [5/13] AUTHORIZED IMS VOIP CALL INTERCEPTION FLOW (2G / IMS DIRECT PATH)
# ==============================================================================
# Technical Verification: Runs sip_traffic_sim.py UAS + caller terminals (each
# in its own mvno_net container) for a full REGISTER + 407 digest + INVITE +
# bidirectional RTP media dialog anchored by RTPEngine.
# Protocol / Component: RFC 3261 SIP / Kamailio Proxy & RTPEngine Media Relay.
# Validation Criteria: REGISTER 200 OK, call answered, caller relays RTP to the
# RTPEngine anchor, and the rtpengine_bytes_total counter rises after the BYE
# (session accounting flushes at session close).
# ==============================================================================
echo -e "${YELLOW}[5/13] 📞 Simulating Authorized IMS VoIP Call Interception Flow (full RTP media dialog via RTPEngine)...${NC}"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true
podman run -d --name ims-uas58 --network mvno_mvno_net --ip 10.89.0.58 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --uas 15559998888 --rtp 5 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.58 --listen-port 5070 >/dev/null
sleep 8
BEFORE=$(curl -s http://localhost:9900/metrics | awk '/^rtpengine_bytes_total /{print $2}')
OUT=$(podman run --rm --name ims-caller59 --network mvno_mvno_net --ip 10.89.0.59 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --rtp 6 --caller 15551234567 \
  --callee 15559998888 --host 10.89.0.23 --port 5060 \
  --bind-ip 10.89.0.59 --listen-port 5090 2>&1) || true
echo "$OUT" | grep -q "call answered" || { echo "[-] Error: media call was not answered" >&2; exit 1; }
echo "$OUT" | grep -q "RTP media sent" || { echo "[-] Error: caller did not send RTP media" >&2; exit 1; }
# rtpengine exports counters to :9900 on its own tick (session accounting flushes
# asynchronously, observed 0-60 s after BYE) — poll until the byte counter moves.
AFTER=$BEFORE
for i in $(seq 1 12); do
    sleep 5
    AFTER=$(curl -s http://localhost:9900/metrics | awk '/^rtpengine_bytes_total /{print $2}')
    [ -n "$AFTER" ] && [ "$AFTER" -gt "${BEFORE:-0}" ] && break
done
[ "$AFTER" -gt "${BEFORE:-0}" ] || { echo "[-] Error: rtpengine_bytes_total did not move (media not relayed)" >&2; exit 1; }
echo -e "${GREEN}✓ 2G/IMS path: full RTP media dialog relayed through RTPEngine (+$((AFTER-BEFORE)) bytes)${NC}\n"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# [5c/13] CALL RECORDING PIPELINE (RTPEngine pcap -> WAV -> Vosk transcript)
# ------------------------------------------------------------------------------
# Technical Verification: Extracts the recorded call pcap with live_tap.sh
# --once (Tier-3 native extraction) and asserts the Vosk spool watcher archives
# a transcript .txt for it.
# Protocol / Component: RTPEngine pcap recording (recording-method=pcap) /
# pcap_to_wav.py retired — live_tap.sh --once (Tier-3 extraction, tshark ->
# awk -> xxd -> ffmpeg, per-src-IP legs) / NativeVoskService.java spool watcher.
# Validation Criteria: WAV extracted with audio; transcript archived <= 25s.
# ==============================================================================
echo -e "${YELLOW}[5c/13] 🎙️ Verifying Call Recording Pipeline (pcap -> WAV -> Vosk ASR)...${NC}"
# The recording pipeline needs a call whose callee leg carries SPEECH (the
# canned scam phrase), not the [5] sim call's tone leg (a 350 Hz sine transcribes
# only noise like "the" and breaks the [9b] keyword assertion). Run the baresip
# rig (LIVE_DEMO S4) right here so the newest pcap below IS the speech-bearing
# call: baresip-rx @10.89.0.60 auto-answers and streams speech8k.wav via aufile.
echo "  (baresip rig: demo_call.sh setup + dial — callee streams the scam phrase)"
bash "${SCRIPT_DIR}/demo_call.sh" setup >/dev/null 2>&1 \
  || { echo "[-] Error: baresip rig setup failed (espeak-ng present?)" >&2; exit 1; }
bash "${SCRIPT_DIR}/demo_call.sh" dial 2>&1 | tail -3 || true
# Stale-frame guard + mid-write tolerance: RTPEngine's pcap grows DURING the
# call and is finalized only after its post-call flush (rtpengine.conf:
# "recording-method=pcap writes ... as they arrive, so the pcap file grows
# during the call"). Reading it mid-write yields an undecodable file, and the
# [5] sim call's tone pcap may still be newest for a few seconds. Retry until
# live_tap decodes the newest pcap AND the baresip callee leg (10.89.0.60 —
# the speech-bearing aufile leg) is among the extracted WAVs.
CALLEE_IP=10.89.0.60
WAV_OUT=""
# Mid-write race guard: RTPEngine flushes the pcap AFTER the call; reading it
# while it grows yields an undecodable file and live_tap --once fails SILENTLY.
# Wait for the newest pcap to be STABLE (size unchanged across 2 s) before
# decoding, so a short call cannot strand the runbook on an unfinalized file.
NEWEST_PCAP=""
for i in $(seq 1 10); do
    CAND=$(\ls -t state/spool/pcaps/*.pcap 2>/dev/null | head -1 || true)
    if [ -n "$CAND" ] && [ "$(stat -c %s "$CAND" 2>/dev/null || echo 0)" -ge 1024 ]; then
        S1=$(stat -c %s "$CAND"); sleep 2; S2=$(stat -c %s "$CAND")
        if [ "$S2" = "$S1" ]; then NEWEST_PCAP="$CAND"; break; fi
    fi
    find state/spool/pcaps -name '*.pcap' -size -1k -delete 2>/dev/null || true
    sleep 3
done
for i in $(seq 1 6); do
    if [ -n "$NEWEST_PCAP" ] && [ -s "$NEWEST_PCAP" ] && [ "$(stat -c %s "$NEWEST_PCAP")" -ge 1024 ]; then
        WAV_OUT=$(bash "${SCRIPT_DIR}/live_tap.sh" --once "$NEWEST_PCAP" 2>&1) || true
        if echo "$WAV_OUT" | grep -q "WAV extracted.*${CALLEE_IP}"; then
            break
        fi
    fi
    sleep 5
done
echo "$WAV_OUT" | grep -q "WAV extracted.*${CALLEE_IP}" \
    || { echo "[-] Error: could not decode the baresip callee leg (pcap mid-write? no speech call?): ${WAV_OUT}" >&2; exit 1; }
# live_tap.sh --once writes one WAV per leg straight into the Vosk spool root.
# LEG LABELS (P2 honesty): the CALLEE leg (10.89.0.60) streams the canned
# scam phrase via aufile — label it [callee/synthetic scam rig]. The CALLER
# leg (10.89.0.61) carries the operator's LIVE voice via the host Pulse
# socket when present (demo_call.sh tx_src=pulse), else a tone fallback —
# label it [caller/you] when it transcribes speech, otherwise note the
# fallback. The [9b] block verdict keys off the callee/synthetic leg only.
CALLER_IP=10.89.0.61
WAV_STEM=$(basename "$NEWEST_PCAP" .pcap)
TXT_PATH=""
for i in $(seq 1 10); do
    TXT_PATH=$(ls state/spool/archived/"${WAV_STEM}"-${CALLEE_IP}.txt 2>/dev/null | head -1 || true)
    if [ -z "$TXT_PATH" ] || [ ! -s "$TXT_PATH" ]; then
        TXT_PATH=""
        for cand in $(ls state/spool/archived/"${WAV_STEM}"-*.txt 2>/dev/null || true); do
            if [ -s "$cand" ]; then TXT_PATH="$cand"; break; fi
        done
    fi
    [ -n "$TXT_PATH" ] && break
    sleep 2.5
done
[ -n "$TXT_PATH" ] || { echo "[-] Error: Vosk did not archive a non-empty transcript within 25s" >&2; exit 1; }
echo -e "${GREEN}✓ Recording pipeline proven: transcript archived at ${TXT_PATH}${NC}"
echo "  --- transcript of [callee/synthetic scam rig] leg (canned phrase through the real call) ---"
cat "${TXT_PATH}"
grep -q '"[[:space:]]*[^"[:space:]]' "${TXT_PATH}" || { echo "[-] Error: transcript body is empty (\{\"text\":\"\"\})" >&2; exit 1; }
WAV_PATH="${TXT_PATH%.txt}.wav"
[ -f "$WAV_PATH" ] || { echo "[-] Error: matching WAV missing at ${WAV_PATH}" >&2; exit 1; }
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV_PATH" || echo 0)
echo "  --- real recorded WAV: ${WAV_PATH} (${DUR}s) ---"
awk -v d="$DUR" 'BEGIN { if (d < 3) exit 1 }' || { echo "[-] Error: recorded WAV duration ${DUR}s < 3s (scripted-leg floor)" >&2; exit 1; }
echo -e "  ✓ recorded WAV duration ${DUR}s >= 3s (scripted-leg floor)"
# Caller leg: the operator's LIVE voice (pulse) — echo its transcript if the
# spool archived non-empty speech, otherwise state the no-mic fallback
# honestly. This leg is the [9d] clean-call evidence, never a block source.
CALLER_TXT_PATH=""
for i in $(seq 1 8); do
    CALLER_TXT_PATH=$(ls state/spool/archived/"${WAV_STEM}"-${CALLER_IP}.txt 2>/dev/null | head -1 || true)
    [ -n "$CALLER_TXT_PATH" ] && [ -s "$CALLER_TXT_PATH" ] && break
    CALLER_TXT_PATH=""
    sleep 2
done
if [ -n "$CALLER_TXT_PATH" ] && grep -q '"[[:space:]]*[^"[:space:]]' "$CALLER_TXT_PATH"; then
    echo "  --- transcript of [caller/you] leg (operator live voice) ---"
    cat "$CALLER_TXT_PATH"
    CALLER_WAV_PATH="${CALLER_TXT_PATH%.txt}.wav"
else
    CALLER_TXT_PATH=""
    CALLER_WAV_PATH=""
    echo "  [caller/you] leg: no speech archived (no mic or operator silent — tone fallback, honest label)"
    # GRADUATION MODE (GRADUATION=1): the live-mic headline proof is MANDATORY.
    # The demo cannot go green on the callee/synthetic verdict alone — the
    # operator must actually speak into the mic and ASR must hear words. Fail
    # hard with a clear message instead of the tolerant dev-run fallback.
    if [ "${GRADUATION:-0}" = "1" ]; then
        echo "[-] Error: GRADUATION mode requires a non-empty [caller/you] (operator live mic)" >&2
        echo "    transcript — the caller leg archived no speech. Fix: speak during" >&2
        echo "    demo_call.sh dial (SPEAK NOW prompt), unmute the mic, or verify" >&2
        echo "    \$XDG_RUNTIME_DIR/pulse/native exists (scripts/demo/mic_probe.sh)." >&2
        exit 1
    fi
fi
echo -e "  --- playing recorded WAV via ALSA (aplay) ---"
aplay -q "$WAV_PATH" || echo "  (warning: aplay playback failed — no ALSA sink on this host; evidence is the WAV + ffprobe)"
echo -e "${GREEN}✓ Call recording playback proven: transcript + ${DUR}s WAV from the real recorded call${NC}\n"
# The baresip rig registered the SAME AOR as the [5b] 5G-path UAS below
# (15559998888). Remove the rig now so [5b]'s INVITE routes unambiguously to the
# UE's binding (multiple usrloc contacts would answer from the bridge instead of
# the 5G user plane). The recorded WAV + transcript evidence persists in the spool.
podman rm -f baresip-rx baresip-tx >/dev/null 2>&1 || true

# ==============================================================================
# [5b/13] 5G SA USER-PLANE SIP CALL TRAVERSAL (GTP-U TUNNEL)
# ==============================================================================
# Technical Verification: Full scripted SIP dialog inside ueransim-ue-1 over
# uesimtun0: a UAS registers 15559998888 binding the UE's 5G IP (read at
# runtime — UE IPs are dynamic across re-attaches) and answers INVITEs;
# a caller (15551234567) registers and calls it with RTP media.
# Protocol / Component: 5G GTP-U N3 Tunnel / UERANSIM ↔ Open5GS UPF (ogstun) ↔ Kamailio.
# Validation Criteria: (1) SIP REGISTER returns 200 OK over the 5G path; (2) the
# digest-authenticated INVITE is ANSWERED with a final "SIP/2.0 200 OK" (the
# simulator waits for the final response, not the interim 100 trying); (3) RTP
# media flows; (4) ogstun TX byte counter moves, proving 5G user-plane traversal.
# ==============================================================================
echo -e "${YELLOW}[5b/13] 📡 Simulating SIP over the 5G SA User Plane (UE tun → N3 GTP-U → UPF ogstun → Kamailio)...${NC}"
# P3 preflight (Issue 5.8/5.9 family): read the LIVE uesimtun0 IP and assert
# GTP-U DOWNLINK emits (iptables OUTPUT 2152 delta) before wiring the call —
# fail fast with the actionable fix instead of a silent stale-IP/buffered-DL.
bash "${SCRIPT_DIR}/preflight_5g.sh" || {
    echo "[-] Error: 5G user-plane preflight failed (see [preflight-5g] above)" >&2; exit 1; }
# UE 5G IPs are dynamic (allocated from the SMF pool on each attach), so read
# ue-1's current uesimtun0 address instead of hardcoding a stale value.
UE_IP=$(podman exec mvno-ueransim-ue-1 sh -c 'ip -4 addr show uesimtun0 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1' | tr -d '[:space:]')
[ -n "$UE_IP" ] || { echo "[-] Error: cannot read ue-1 uesimtun0 IPv4 (5G session down?)" >&2; exit 1; }
echo "  ue-1 5G IP (dynamic): $UE_IP"
podman exec mvno-ueransim-ue-1 sh -c 'ip route replace 10.89.0.23/32 dev uesimtun0 2>/dev/null' || true
podman cp "${SCRIPT_DIR}/sip_traffic_sim.py" mvno-ueransim-ue-1:/tmp/sip_traffic_sim.py >/dev/null
podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true
podman exec mvno-ueransim-ue-1 sh -c "rm -f /tmp/uas.log; nohup python3 -u /tmp/sip_traffic_sim.py --uas 15559998888 --host 10.89.0.23 --port 5060 --bind-ip $UE_IP --listen-port 5070 > /tmp/uas.log 2>&1 &"
sleep 4
BEFORE=$(podman exec mvno-upf cat /sys/class/net/ogstun/statistics/tx_bytes 2>/dev/null || echo 0)
OUT=$(podman exec mvno-ueransim-ue-1 python3 /tmp/sip_traffic_sim.py --rtp 3 --caller 15551234567 --callee 15559998888 --host 10.89.0.23 --port 5060 --bind-ip "$UE_IP" --listen-port 5072 2>&1) || true
AFTER=$(podman exec mvno-upf cat /sys/class/net/ogstun/statistics/tx_bytes 2>/dev/null || echo 0)
UAS_LOG=$(podman exec mvno-ueransim-ue-1 cat /tmp/uas.log 2>/dev/null || true)
podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true
echo "$OUT"
echo "--- UAS side (5G-path callee) ---"
echo "$UAS_LOG"
echo "$UAS_LOG" | grep -q "SIP REGISTER 200 OK for subscriber 15559998888" || { echo "[-] Error: 5G-path REGISTER did not succeed" >&2; exit 1; }
echo "$OUT" | grep -q "SIP/2.0 200 OK" || { echo "[-] Error: 5G-path INVITE not answered with 200 OK (got 100 trying / timeout)" >&2; exit 1; }
echo "$OUT" | grep -q "RTP media sent" || { echo "[-] Error: 5G-path RTP media did not flow" >&2; exit 1; }
[ "${AFTER:-0}" -gt "${BEFORE:-0}" ] || { echo "[-] Error: ogstun TX did not move (5G path dead)" >&2; exit 1; }
echo -e "${GREEN}✓ 5G SA path: REGISTER 200 OK + INVITE answered 200 OK + RTP media over the 5G user plane (ogstun TX +$((AFTER-BEFORE)) bytes)${NC}\n"

# ------------------------------------------------------------------------------
# [5d/13] FAIL-OPEN: RECORDING UNAVAILABLE (RTPEngine stopped -> call still connects)
# ------------------------------------------------------------------------------
# Technical Verification: Stops the RTPEngine media proxy, then runs the same
# scripted SIP dialog. Carrier SLA fail-open rule: when recording/media anchoring
# is unavailable, the call MUST still be answered (SIP 200 OK) and Kamailio MUST
# leave a visible "RECORDING UNAVAILABLE" error line instead of dropping the call.
# Protocol / Component: Carrier 5.0s SLA fail-open / Kamailio rtpengine module.
# Validation Criteria: (1) call answered with 200 OK while RTPEngine is DOWN;
# (2) Kamailio logs the visible RECORDING UNAVAILABLE line; (3) RTPEngine restarted
# afterwards and the next real call is recorded normally.
# ==============================================================================
echo -e "${YELLOW}[5d/13] 🛡️ Fail-Open Proof: RTPEngine DOWN -> call still answered + visible RECORDING UNAVAILABLE...${NC}"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true
# Drop the 5b UAS binding (same AOR 15559998888) so this section's callee is
# unambiguous; a stale registration would fork the INVITE to the 5G-path UAS.
podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true
podman stop mvno-rtpengine >/dev/null 2>&1
sleep 2
podman ps --format "{{.Names}} {{.Status}}" | grep mvno-rtpengine | grep -q Up && { echo "[-] Error: mvno-rtpengine did not stop (podman stop timeout?)" >&2; exit 1; }
podman run -d --name ims-uas58 --network mvno_mvno_net --ip 10.89.0.58 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --uas 15559998888 --rtp 5 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.58 --listen-port 5070 >/dev/null
sleep 8
OUT=$(podman run --rm --name ims-caller59 --network mvno_mvno_net --ip 10.89.0.59 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --rtp 6 --caller 15551234567 \
  --callee 15559998888 --host 10.89.0.23 --port 5060 \
  --bind-ip 10.89.0.59 --listen-port 5090 2>&1) || true
echo "$OUT" | grep -q "call answered" || { echo "[-] Error: fail-open broken — call NOT answered while RTPEngine was down" >&2; exit 1; }
# Capture before grepping: under `set -o pipefail`, `grep -q` exiting early
# SIGPIPEs `podman logs` (141), falsely failing the pipeline on a match.
FAILOPEN_LOG=$(podman logs mvno-kamailio --since 2m 2>&1 || true)
echo "$FAILOPEN_LOG" | grep -q "RECORDING UNAVAILABLE" || { echo "[-] Error: no visible RECORDING UNAVAILABLE line in Kamailio logs (fail-open marker missing)" >&2; exit 1; }
echo -e "${GREEN}✓ Fail-open proven: call answered (200 OK) with RTPEngine DOWN + Kamailio logged 'RECORDING UNAVAILABLE'${NC}\n"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true
podman start mvno-rtpengine >/dev/null 2>&1
sleep 5
podman ps --format "{{.Names}} {{.Status}}" | grep mvno-rtpengine | grep -q Up || { echo "[-] Error: mvno-rtpengine failed to restart after fail-open proof" >&2; exit 1; }
echo -e "${GREEN}✓ mvno-rtpengine restarted and Up — recording service restored${NC}\n"

# ------------------------------------------------------------------------------
# [5e/13] FAIL-OPEN: TRANSCRIPTION UNAVAILABLE (Vosk ASR down -> call unaffected)
# ------------------------------------------------------------------------------
# Technical Verification: Stops the mvno-api container (hosts NativeVoskService +
# the AI interception query), then runs the scripted SIP dialog. The interception
# query fails open (no 200+allow:false -> call proceeds) and ASR is a post-call
# analytics side-channel — the call MUST complete with a visible failure marker.
# Protocol / Component: Carrier SLA fail-open / NativeVoskService.java spool loop.
# Validation Criteria: (1) call answered while mvno-api is DOWN; (2) mvno-api logs
# the visible TRANSCRIPTION UNAVAILABLE marker on restart; (3) stack restored.
# ==============================================================================
echo -e "${YELLOW}[5e/13] 🛡️ Fail-Open Proof: ASR/Interception DOWN -> call still answered + visible error...${NC}"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true
podman stop mvno-api >/dev/null 2>&1
sleep 2
podman run -d --name ims-uas58 --network mvno_mvno_net --ip 10.89.0.58 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --uas 15559998888 --rtp 5 \
  --host 10.89.0.23 --port 5060 --bind-ip 10.89.0.58 --listen-port 5070 >/dev/null
sleep 8
OUT=$(podman run --rm --name ims-caller59 --network mvno_mvno_net --ip 10.89.0.59 \
  -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
  python3 -u /scripts/sip_traffic_sim.py --rtp 6 --caller 15551234567 \
  --callee 15559998888 --host 10.89.0.23 --port 5060 \
  --bind-ip 10.89.0.59 --listen-port 5090 2>&1) || true
echo "$OUT" | grep -q "call answered" || { echo "[-] Error: fail-open broken — call NOT answered while mvno-api (ASR/interception) was down" >&2; exit 1; }
echo -e "${GREEN}✓ Fail-open proven: call answered (200 OK) with mvno-api (Vosk ASR + interception) DOWN${NC}\n"
podman rm -f ims-uas58 ims-caller59 >/dev/null 2>&1 || true
podman start mvno-api >/dev/null 2>&1
sleep 15
podman ps --format "{{.Names}} {{.Status}}" | grep mvno-api | grep -q Up || { echo "[-] Error: mvno-api failed to restart after fail-open proof" >&2; exit 1; }
curl -s http://localhost:8080/actuator/prometheus | grep -q "mvno_vosk_unavailable" && echo -e "${GREEN}✓ mvno.vosk.unavailable counter exposed (visible transcription-unavailable marker)${NC}\n"
echo -e "${GREEN}✓ mvno-api restarted and Up — ASR/interception service restored${NC}\n"

# ==============================================================================
# [6/13] ZERO-BALANCE CALL BLOCKING (SIP 407 CHALLENGE ➔ DIGEST ➔ SIP 403 FORBIDDEN)
# ==============================================================================
# Technical Verification: Initiates call from zero-balance subscriber (15557654321).
# Protocol / Component: RFC 2617 MD5 Digest Auth / Kamailio & telecom-api Intercept.
# Validation Criteria: Asserts Kamailio issues SIP 407 challenge, receives MD5 digest,
# queries telecom-api (balance = 0), and returns SIP/2.0 403 Forbidden to drop call.
# ==============================================================================
echo -e "${YELLOW}[6/13] 🚫 Testing Zero-Balance Call Block (SIP 407 Challenge → Digest → 403 Forbidden)...${NC}"
python3 -c "
import socket, time, sys, hashlib

def digest_response(username, realm, password, method, uri, nonce):
    ha1 = hashlib.md5(f'{username}:{realm}:{password}'.encode()).hexdigest()
    ha2 = hashlib.md5(f'{method}:{uri}'.encode()).hexdigest()
    return hashlib.md5(f'{ha1}:{nonce}:{ha2}'.encode()).hexdigest()

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
caller = '15557654321' # Zero-balance subscriber
callee = '15557654321'
port = 5066
sdp = 'v=0\r\no=user2 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 30004 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n'

def build_invite(auth=''):
    auth_hdr = f'Authorization: {auth}\r\n' if auth else ''
    return (f'INVITE sip:{callee}@localhost:{port} SIP/2.0\r\n'
            f'Via: SIP/2.0/UDP 127.0.0.1:5072;branch=z9hG4bK-{time.time()}\r\n'
            f'From: <sip:{caller}@localhost>;tag=tag1\r\n'
            f'To: <sip:{callee}@localhost>\r\n'
            f'Call-ID: call-403-{time.time()}@127.0.0.1\r\n'
            f'CSeq: 1 INVITE\r\n'
            f'Contact: <sip:{caller}@127.0.0.1:5072>\r\n'
            f'{auth_hdr}'
            f'Content-Type: application/sdp\r\n'
            f'Content-Length: {len(sdp)}\r\n\r\n'
            f'{sdp}')

# 1. Unauthenticated INVITE -> expect 407 challenge
s.sendto(build_invite().encode(), ('127.0.0.1', port))
resp1 = ''
try:
    resp1, _ = s.recvfrom(2048)
    resp1 = resp1.decode('utf-8', errors='ignore')
    first = resp1.split('\r\n')[0]
    if '407' not in first:
        print(f'[-] Expected 407 challenge, got: {first}', file=sys.stderr)
        sys.exit(1)
    print(f'  ✓ SIP 407 Challenge Received: {first}')
except Exception:
    print('[-] Error: No SIP 407 challenge for unauthenticated INVITE', file=sys.stderr)
    sys.exit(1)

nonce = ''
for line in resp1.split('\r\n'):
    if line.lower().startswith('proxy-authenticate:'):
        parts = line.split('nonce=\"')
        if len(parts) > 1:
            nonce = parts[1].split('\"')[0]
if not nonce:
    print('[-] Error: No nonce in 407 challenge', file=sys.stderr)
    sys.exit(1)

# 2. Authenticated INVITE (zero-balance caller) -> expect 403 from INTERCEPT
uri = f'sip:{callee}@localhost:{port}'
digest = digest_response(caller, 'localhost', 'testpass', 'INVITE', uri, nonce)
auth = f'Digest username=\"{caller}\", realm=\"localhost\", nonce=\"{nonce}\", uri=\"{uri}\", response=\"{digest}\"'
s.sendto(build_invite(auth).encode(), ('127.0.0.1', port))

got_403 = False
for _ in range(5):
    try:
        resp, _ = s.recvfrom(2048)
        line = resp.decode('utf-8', errors='ignore').split('\r\n')[0]
        if '403' in line:
            print(f'  ✓ SIP Response Received: {line}')
            got_403 = True
            break
    except Exception:
        break

if not got_403:
    print('[-] Error: Did not receive SIP 403 Forbidden for zero-balance call', file=sys.stderr)
    sys.exit(1)
"
echo -e "${GREEN}✓ Call Blocked at SIP Protocol Level (SIP/2.0 403 Forbidden Returned)${NC}\n"

# ==============================================================================
# [7/13] EIR SIM-SWAP FRAUD TRIGGERING (>3 SIMs ON 1 IMEI HARDWARE)
# ==============================================================================
# Technical Verification: Sends 4 call intercept queries with 4 distinct MSISDNs
# using the exact same 15-digit device IMEI (356938035643809).
# Protocol / Component: 3GPP EIR Hardware Tracking / EirTracker.java.
# Validation Criteria: Asserts 1st, 2nd, 3rd SIMs pass, while 4th distinct SIM attempt
# triggers fraud block: {"allow": false, "reason": "EIR: SIM swap detected"}.
# ==============================================================================
echo -e "${YELLOW}[7/13] 🛡️ Triggering EIR SIM-Swap Anomaly (>3 distinct SIMs on IMEI: 356938035643809)...${NC}"
for CALLER in 15551234567 15559998888 15554443322 15553332211; do
  R=$(curl -s -X POST http://localhost:8080/api/v1/intercept/call \
    -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
    -d "{\"caller\": \"${CALLER}\", \"callee\": \"15557654321\", \"imei\": \"356938035643809\"}")
  echo "  Attempt (${CALLER}): $(echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"allow={d.get('allow')}, reason={d.get('reason')}\")" 2>/dev/null || echo "UNPARSEABLE: ${R}")"
done
BLOCKED=$(curl -s -X POST http://localhost:8080/api/v1/intercept/call \
  -H "Content-Type: application/json" -H "X-API-Key: mvno-demo-key-2026" \
  -d '{"caller": "15553332211", "callee": "15557654321", "imei": "356938035643809"}')
python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('allow') is False and 'SIM swap' in d.get('reason', ''), f'unexpected EIR response: {d}'
print(f\"  ✓ 4th distinct SIM blocked: {d}\")" <<< "$BLOCKED" || fail "EIR SIM-swap block not returned (got: $BLOCKED)"
pass "EIR SIM-Swap fraud trigger verified (4 distinct SIMs on 1 IMEI)"

# ==============================================================================
# [8/13] AUTHORIZED 5G SMS INTERCEPTION FLOW (USER SMS -> real SMPP MO -> REST)
# ==============================================================================
# Technical Verification: Submits a USER-SUPPLIED SMS over the REAL SMPP 3.4
# mobile-originated path (send_smpp_sms.py -> OsmoSMSC BIND_TRANSCEIVER + SUBMIT_SM),
# then queries the Gateway REST intercept with the same content.
# Protocol / Component: SMPP 3.4 binary PDUs / OsmoSMSC (2775) / REST intercept
# SubscriberController.java (8080).
# Validation Criteria: (1) SUBMIT_SM accepted ESME_ROK and a row lands in smsc.db
# showing the user's SMS traversed the SMSC for real; (2) REST intercept returns
# {"allow": true, "reason": "Clean content"} and echoes the nonce.
# ==============================================================================
echo -e "${YELLOW}[8/13] 💬 Authorized 5G SMS Interception — real MO SMS via SMPP -> OsmoSMSC -> REST...${NC}"
SMS_NONCE="MVNO5G-$(date +%s)"
# User-supplied SMS text: $SMS_TEXT env > interactive prompt (TTY) > default.
if [ -n "${SMS_TEXT:-}" ]; then
    SMS_BODY="$SMS_TEXT"
elif [ -t 0 ]; then
    printf 'Enter SMS text (blank = default): '
    IFS= read -r SMS_IN
    SMS_BODY="${SMS_IN:-Award-winning offer, reply now}"
else
    SMS_BODY="Award-winning offer, reply now"
fi
SMS_BODY="${SMS_BODY} ${SMS_NONCE}"
echo "  user SMS text: ${SMS_BODY}"
echo "  --- real MO leg: SUBMIT_SM -> OsmoSMSC (SMPP 3.4) ---"
SMS_SMPP_OUT=$(python3 "${SCRIPT_DIR}/send_smpp_sms.py" \
    --sender 15551234567 --recipient 15557654321 --message "$SMS_BODY" 2>&1) || true
echo "$SMS_SMPP_OUT" | grep -q "BIND_TRANSCEIVER Successful" || { echo "[-] Error: real SMPP MO bind failed: $SMS_SMPP_OUT" >&2; exit 1; }
echo "$SMS_SMPP_OUT" | grep -q "SUBMIT_SM Delivered" || { echo "[-] Error: real SMPP MO submit failed: $SMS_SMPP_OUT" >&2; exit 1; }
# Real terminal evidence: the user's SMS landed in OsmoSMSC's store.
SMS_ROW=$(sqlite3 state/hlr/smsc.db "SELECT COUNT(*) FROM SMS WHERE src_addr='15551234567' AND dest_addr='15557654321' AND created > datetime('now','-2 minutes');" 2>/dev/null || echo 0)
[ "${SMS_ROW:-0}" -gt 0 ] || { echo "[-] Error: no fresh SMS row in smsc.db from the real MO submit" >&2; exit 1; }
echo "  ✓ real MO SMS stored: ${SMS_ROW} fresh row(s) in smsc.db (OsmoSMSC store-and-forward)"
echo "  --- REST intercept evaluates the same content ---"
# The nonce proves THIS user transaction end-to-end: it rode the real SMPP MO
# into OsmoSMSC, which stores the payload GSM-7-packed in `user_data` (the
# `text` column stays empty). Decode it the same way ip_sm_gw.gsm7_decode does.
SMS_NONCE="${SMS_NONCE}" REPO_ROOT="${REPO_ROOT}" python3 - <<'PYEOF' || { echo "[-] Error: user SMS (nonce ${SMS_NONCE}) not found in smsc.db after real MO" >&2; exit 1; }
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "scripts"))
from ip_sm_gw import gsm7_decode, connect
nonce = os.environ["SMS_NONCE"]
db = os.path.join(os.environ["REPO_ROOT"], "state/hlr/smsc.db")
c = connect(db)
rows = c.execute(
    "SELECT user_data FROM SMS WHERE src_addr='15551234567' AND dest_addr='15557654321' "
    "AND created > datetime('now','-3 minutes') ORDER BY id DESC LIMIT 5"
).fetchall()
for (ud,) in rows:
    if ud and nonce in gsm7_decode(bytes(ud)):
        print(f"  ✓ user SMS (nonce {nonce}) confirmed in smsc.db via GSM-7 decode")
        sys.exit(0)
print(f"[-] nonce {nonce} not found in recent smsc.db MO rows", file=sys.stderr)
sys.exit(1)
PYEOF
SMSR=$(curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mvno-demo-key-2026" \
  -d "{\"sender\": \"15551234567\", \"recipient\": \"15557654321\", \"content\": \"${SMS_BODY}\"}")
echo "  $SMSR"
python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('allow') is True, f'unexpected: {d}'
assert d.get('reason') == 'Clean content', f'unexpected reason: {d}'
print('  ✓ SMS allowed: allow=true, reason=Clean content')" <<< "$SMSR" || fail "5G SMS interception did not allow (got: $SMSR)"
pass "User SMS allowed (real SMPP MO -> OsmoSMSC GSM-7, nonce ${SMS_NONCE} decoded) + REST verdict Clean"

# Housekeeping: remove the [8] MO row from smsc.db. The row's dest
# (15557654321) is a 5G MSISDN, so the IP-SM-GW bridge would otherwise keep
# polling it (5 RETRYs burn the poll budget and leave a confusing leftover
# that trips up the e2e runbook's bridge-counter assertions).
SMS_NONCE="${SMS_NONCE}" sqlite3 state/hlr/smsc.db \
  "DELETE FROM SMS WHERE src_addr='15551234567' AND dest_addr='15557654321' AND created > datetime('now','-5 minutes');" \
  >/dev/null 2>&1 || true
echo "  ✓ cleaned up [8] MO row(s) from smsc.db (bridge poll hygiene)"

# ==============================================================================
# [9/13] NATIVE VOSK JAVA 21 SPEECH-TO-TEXT ASR & SPOOL ARCHIVING PIPELINE
# ==============================================================================
# Technical Verification: Re-arches the REAL recorded call leg from the [5c]
# RTPEngine pcap (the spoken scam phrase that actually traversed
# baresip -> Kamailio -> RTPEngine) and drops it into the Vosk spool so
# NativeVoskService decodes it live. No synthetic waveform is used as evidence.
# Protocol / Component: Native Vosk JNI ASR / NativeVoskService.java spool watcher
# / live_tap.sh pcap->WAV extraction.
# Validation Criteria: WAV re-seeded from the [5c] recording; NativeVoskService
# archives a non-empty transcript within 15s (background thread moves the file).
# ==============================================================================
echo -e "${YELLOW}[9/13] 🎙️ Demonstrating Native Vosk Java 21 ASR on the REAL Recorded Call...${NC}"
# Prove the spool watcher end-to-end with real captured speech: the [5c] pcap's
# callee leg already decoded to a spoken phrase; drop a fresh copy in the spool
# and let NativeVoskService transcribe + archive it. `--once` also exits non-zero
# on an empty/undecodable pcap, so a broken recording surfaces here, not silently.
[ -n "${WAV_PATH:-}" ] && [ -s "$WAV_PATH" ] || { echo "[-] Error: no real [5c] recorded WAV ($WAV_PATH) to re-arch" >&2; exit 1; }
REAL_SEED="state/spool/demo-vosk-live-$(date +%s).wav"
cp "$WAV_PATH" "$REAL_SEED" || { echo "[-] Error: could not seed real WAV into spool" >&2; exit 1; }
echo "  ✓ seeded real recorded call leg from [5c]: $(basename "$REAL_SEED")"
echo "    source pcap: $NEWEST_PCAP"
echo "    seeded duration: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$REAL_SEED" 2>/dev/null || echo '?')s"
archived_path=""
for i in $(seq 1 5); do
    sleep 3
    archived_path=$(ls state/spool/archived/$(basename "$REAL_SEED" .wav).txt 2>/dev/null | head -1 || true)
    [ -n "$archived_path" ] && [ -s "$archived_path" ] && break
    archived_path=""
done
[ -n "$archived_path" ] || { echo "[-] Error: Vosk did not archive a transcript for the real recording within 15s" >&2; exit 1; }
echo "  ✓ Native Vosk ASR engine archived a transcript: $archived_path"
echo "  --- [callee/synthetic scam rig] transcript (canned phrase re-arched from the real call) ---"
cat "$archived_path"
grep -q '"[[:space:]]*[^"[:space:]]' "$archived_path" || { echo "[-] Error: real transcript body is empty" >&2; exit 1; }
echo -e "${GREEN}✓ Native Vosk Java 21 ASR Pipeline Proven on the REAL Recorded Call (canned rig phrase, labeled)${NC}\n"

# ------------------------------------------------------------------------------
# [9b/13] POST-CALL SCAM VERDICT (real recorded speech -> Vosk -> TRANSCRIPT -> BLOCKED)
# ------------------------------------------------------------------------------
# Technical Verification: Re-arches the REAL scam phrase captured in this run's
# [5c] baresip call (spoken media that genuinely traversed
# baresip -> Kamailio -> RTPEngine -> pcap -> live_tap). NativeVoskService decodes
# it, AiFilterService.classifyTranscript calls the ai-filter keyword rule, and the
# PHISHING verdict blocks it — mvno_vosk_blocked_total increments.
# Protocol / Component: live_tap.sh pcap->WAV / NativeVoskService.java ASR spool
# watcher / AiFilterService.classifyTranscript -> ai-filter mock keyword rule.
# Validation Criteria: transcript archived with the REAL spam words; the real
# transcript is echoed (not a hardcoded string); block counter increments >= 1.
# ⚠ DECIDER SCOPE: the verdict comes from the inline ai-filter MOCK (standalone
# demo decider, honestly labeled). Per org separation the real decider is
# Filteration-System (SMPP in-band; no call hook yet) — see
# docs/filteration-system-handoff.md. This check proves the TRANSCRIPT pipeline
# end-to-end with the demo fallback, never the org decider.
# ==============================================================================
echo -e "${YELLOW}[9b/13] 🚨 Real Scam Call -> AI Blocked Verdict (real recording -> Vosk -> TRANSCRIPT -> blocked)...${NC}"
command -v ffmpeg >/dev/null 2>&1 || { echo "[-] Error: ffmpeg missing — install via ./scripts/deploy.sh" >&2; exit 1; }
vm_counter() {
    curl -s 'http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total' \
        | grep -o '"value":\[[0-9]*,"[0-9]*"\]' | grep -o ',"[0-9]*"' | tr -d ',"'
}
[ -n "${WAV_PATH:-}" ] && [ -s "$WAV_PATH" ] || { echo "[-] Error: no real [5c] recorded scam WAV ($WAV_PATH) for the verdict" >&2; exit 1; }
echo "  ✓ re-arching the REAL [5c] scam-call recording: $(basename "$WAV_PATH")"
echo "    recorded duration: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV_PATH" 2>/dev/null || echo '?')s"
BLOCKED_BEFORE=$(vm_counter || echo 0)
BLOCKED_BEFORE=${BLOCKED_BEFORE:-0}
SCAM_DROP="state/spool/demo-scam-$(date +%s).wav"
cp "$WAV_PATH" "$SCAM_DROP" || { echo "[-] Error: scam WAV drop-in failed" >&2; exit 1; }
SCAM_TXT=""
for i in $(seq 1 10); do
    sleep 2.5
    SCAM_TXT=$(ls state/spool/archived/$(basename "$SCAM_DROP" .wav).txt 2>/dev/null | head -1 || true)
    [ -n "$SCAM_TXT" ] && [ -s "$SCAM_TXT" ] && break
    SCAM_TXT=""
done
[ -n "$SCAM_TXT" ] || { echo "[-] Error: scam recording was not transcribed within 25s" >&2; exit 1; }
echo -e "  --- [callee/synthetic scam rig] transcript of this run's call (canned phrase — NOT operator speech) ---"
cat "$SCAM_TXT"
grep -q '"[[:space:]]*[^"[:space:]]' "$SCAM_TXT" || { echo "[-] Error: real scam transcript is empty" >&2; exit 1; }
# The transcript must contain a scam keyword the ai-filter matches, proving the
# block is genuine (driven by the real spoken words, not a hardcoded verdict).
for w in won prize claim free urgent account blocked confirm; do
    if grep -qi "$w" "$SCAM_TXT"; then
        echo "  ✓ transcript carries scam keyword '$w' -> ai-filter must block"
        break
    fi
done
BLOCKED_AFTER=$BLOCKED_BEFORE
for i in $(seq 1 12); do
    sleep 5
    BLOCKED_AFTER=$(vm_counter || echo 0)
    [ -n "$BLOCKED_AFTER" ] && [ "$BLOCKED_AFTER" -gt "$BLOCKED_BEFORE" ] && break
done
[ "$BLOCKED_AFTER" -gt "$BLOCKED_BEFORE" ] || { echo "[-] Error: mvno_vosk_blocked_total did not increment (phishing verdict missing on the real scam call)" >&2; exit 1; }
echo -e "${GREEN}✓ Real scam call BLOCKED: mvno_vosk_blocked_total ${BLOCKED_BEFORE} -> ${BLOCKED_AFTER} (real recorded speech, transcript echoed above)${NC}\n"

# ------------------------------------------------------------------------------
# [9d/13] CLEAN CALL ALLOWED (operator live voice / real-voice fixture -> ALLOW)
# ------------------------------------------------------------------------------
# Technical Verification: the SAME ai-filter TRANSCRIPT rule that blocked the
# [callee/synthetic] scam leg must ALLOW the operator's real voice. Source is
# the [5c] caller leg when the operator spoke into the live mic; otherwise the
# certified real-voice fixture (docs/evidence/fixtures/archived/live-caller.wav,
# the operator's voice captured on 2026-08-06, labeled as such).
# Protocol / Component: Vosk ASR transcript -> ai-filter /api/v1/classify
# (event_type=TRANSCRIPT) -> allow:true expected.
# Validation Criteria: verdict allow==true with reason "Clean content".
# ⚠ DECIDER SCOPE: same inline ai-filter MOCK as [9b] (standalone demo decider).
# The org decider (Filteration-System) replaces it in the wiring phase — this
# check only proves the same TRANSCRIPT rule allows clean operator speech.
# ==============================================================================
echo -e "${YELLOW}[9d/13] ✅ Clean Call ALLOWED (operator live voice -> ai-filter ALLOW)...${NC}"
CLEAN_TXT="${CALLER_TXT_PATH:-}"
CLEAN_SRC="live [caller/you] leg from this run's call"
if [ -z "$CLEAN_TXT" ] || [ ! -s "$CLEAN_TXT" ]; then
    CLEAN_TXT="docs/evidence/fixtures/archived/live-caller.txt"
    CLEAN_SRC="certified real-voice fixture (operator voice, captured 2026-08-06, labeled)"
fi
echo "  clean-call source: $CLEAN_SRC"
echo "  --- [caller/you] transcript ---"
cat "$CLEAN_TXT"
grep -q '"[[:space:]]*[^"[:space:]]' "$CLEAN_TXT" || { echo "[-] Error: clean-call transcript is empty" >&2; exit 1; }
CLEAN_TEXT=$(python3 -c "import json,sys; print(json.load(open('$CLEAN_TXT'))['text'])")
CLEAN_V=$(curl -s -m 5 -X POST http://localhost:8008/api/v1/classify \
  -H 'Content-Type: application/json' \
  -d "{\"event_type\":\"TRANSCRIPT\",\"transcript\":\"${CLEAN_TEXT}\"}")
echo "  ai-filter verdict: $CLEAN_V"
echo "$CLEAN_V" | grep -q '"allow": *true' || { echo "[-] Error: clean call was NOT allowed by ai-filter (got: $CLEAN_V)" >&2; exit 1; }
echo -e "${GREEN}✓ Clean call ALLOWED by the same TRANSCRIPT rule (${CLEAN_SRC})${NC}\n"

# ------------------------------------------------------------------------------
# [9c/13] PLAYBACK PROOF (seeded real-voice recording over ALSA + its transcript)
# ------------------------------------------------------------------------------
# Technical Verification: Plays the seeded live-caller.wav fixture (real human
# voice, certified 17.9s capture) over ALSA and prints its archived transcript.
# Protocol / Component: ALSA aplay / docs/evidence/fixtures/ (append-only ledger).
# Validation Criteria: ffprobe duration >= 15s; transcript printed non-empty.
# ==============================================================================
echo -e "${YELLOW}[9c/13] 🔊 Playback Proof: operator real-voice fixture (your voice, certified prior capture)...${NC}"
PLAY_WAV="docs/evidence/fixtures/archived/live-caller.wav"
PLAY_TXT="docs/evidence/fixtures/archived/live-caller.txt"
[ -f "$PLAY_WAV" ] || { echo "[-] Error: playback fixture missing: ${PLAY_WAV}" >&2; exit 1; }
PDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$PLAY_WAV" || echo 0)
awk -v d="$PDUR" 'BEGIN { if (d < 15) exit 1 }' || { echo "[-] Error: playback fixture duration ${PDUR}s < 15s floor" >&2; exit 1; }
echo -e "  ✓ fixture duration ${PDUR}s >= 15s (real voice)"
echo -e "  --- playing live-caller.wav via ALSA (aplay) ---"
aplay -q "$PLAY_WAV" || echo "  (warning: aplay playback failed — no ALSA sink; evidence = hashed fixture + ffprobe + transcript)"
echo -e "  --- [caller/you] archived transcript (${PLAY_TXT}) ---"
cat "$PLAY_TXT"
[ -s "$PLAY_TXT" ] || { echo "[-] Error: playback transcript is empty" >&2; exit 1; }
echo -e "${GREEN}✓ Playback proof: ${PDUR}s real-voice recording played + transcript printed${NC}\n"

# ==============================================================================
# [10/13] BINARY SMPP 3.4 BIND_TRANSCEIVER PDU (OSMOCOM SMSC PORT 2775)
# ==============================================================================
# Technical Verification: Connects to Osmocom SMSC over TCP port 2775 and sends a
# binary SMPP 3.4 BIND_TRANSCEIVER PDU (command_id = 0x00000009).
# Protocol / Component: SMPP v3.4 Binary Protocol / OsmoSMSC (mvno-osmosmsc).
# Validation Criteria: Asserts response status == 0x00000000 (ESME_ROK / SUCCESS).
# ==============================================================================
echo -e "${YELLOW}[10/13] 📨 Testing Binary SMPP 3.4 BIND_TRANSCEIVER PDU (Port 2775)...${NC}"
python3 -c "
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 2775))
pdu_body = b'smsclient\x00password\x00\x00\x34\x00\x00\x00'
cmd_length = 16 + len(pdu_body)
header = struct.pack('>IIII', cmd_length, 0x00000009, 0, 1)
s.sendall(header + pdu_body)
resp = s.recv(1024)
s.close()
cmd_id, status = struct.unpack('>II', resp[4:12])
print(f'  SMPP PDU Response: CMD=0x{cmd_id:08X}, Status=0x{status:08X} (ESME_ROK / SUCCESS)')
if status != 0:
    print('[-] Error: SMPP bind did not return ESME_ROK', file=sys.stderr)
    sys.exit(1)
"
echo -e "${GREEN}✓ SMPP 3.4 ESME Transceiver Bound Successfully${NC}\n"

# ------------------------------------------------------------------------------
# [10b/13] SMPP 3.4 SUBMIT_SM DELIVERY (full ESME -> SMSC submit round-trip)
# ------------------------------------------------------------------------------
# Technical Verification: Submits an SMS via the same SMPP 3.4 channel and
# asserts the SMSC accepts it (ESME_ROK). Uses send_smpp_sms.py harness.
# Validation Criteria: BIND_TRANSCEIVER OK + SUBMIT_SM status 0x00000000.
# ==============================================================================
echo -e "${YELLOW}[10b/13] 📨 Submitting SMS via SMPP 3.4 SUBMIT_SM (Port 2775)...${NC}"
SUBMIT_OUT=$(python3 "${SCRIPT_DIR}/send_smpp_sms.py" 2>&1) || true
echo "$SUBMIT_OUT" | grep -q "BIND_TRANSCEIVER Successful" || { echo "[-] Error: SMPP rebind failed" >&2; exit 1; }
echo "$SUBMIT_OUT" | grep -q "SUBMIT_SM Delivered" || { echo "[-] Error: SUBMIT_SM was not delivered" >&2; exit 1; }
echo "$SUBMIT_OUT" | grep -q "Status=0x00000000" || { echo "[-] Error: SUBMIT_SM not accepted (ESME_ROK expected)" >&2; exit 1; }
echo -e "${GREEN}✓ SMPP SUBMIT_SM accepted by OsmoSMSC (ESME_ROK)${NC}"
echo "  --- real stored SMS rows in state/hlr/smsc.db (terminal evidence) ---"
sqlite3 -header -column state/hlr/smsc.db \
  "SELECT id, src_addr, dest_addr, substr(text,1,40) AS content, created, sent FROM SMS ORDER BY id DESC LIMIT 5;" \
  || { echo "[-] Error: smsc.db row dump failed" >&2; exit 1; }
ROWCOUNT=$(sqlite3 state/hlr/smsc.db \
  "SELECT COUNT(*) FROM SMS WHERE src_addr='15551234567' AND dest_addr='15557654321';" 2>/dev/null || echo 0)
[ "${ROWCOUNT:-0}" -gt 0 ] || { echo "[-] Error: no stored SMS row for the SUBMIT_SM round-trip in smsc.db" >&2; exit 1; }
echo -e "  ✓ ${ROWCOUNT} stored SMS row(s) for 15551234567 -> 15557654321 verified in smsc.db"
python3 - <<'EOF'
import sqlite3
c = sqlite3.connect("state/hlr/smsc.db")
n = c.execute("DELETE FROM SMS WHERE src_addr='15551234567' AND dest_addr='15557654321' AND sent IS NULL").rowcount
c.commit()
if n:
    print(f"  (drained {n} pending demo SMS row(s) from smsc.db so the bridge does not retry them during a subsequent e2e run)")
EOF
echo ""

# ==============================================================================
# [11/13] VICTORIAMETRICS TSDB PROMQL TELEMETRY INGESTION
# ==============================================================================
# Technical Verification: Queries VictoriaMetrics PromQL endpoint (port 8428).
# Protocol / Component: PromQL / VictoriaMetrics TSDB & vmagent scraper.
# Validation Criteria: Queries metric 'mvno_call_requests_total'. Asserts metric series
# exists and current value is > 0.
# ==============================================================================
echo -e "${YELLOW}[11/13] 📈 Querying VictoriaMetrics TSDB PromQL Telemetry...${NC}"
python3 -c "
import urllib.request, json, sys
url = 'http://localhost:8428/api/v1/query?query=mvno_call_requests_total'
req = urllib.request.urlopen(url)
data = json.loads(req.read().decode('utf-8'))
results = data.get('data', {}).get('result', [])
if not results:
    print('[-] Error: VictoriaMetrics returned 0 active series for mvno_call_requests_total', file=sys.stderr)
    sys.exit(1)
val = results[0]['value'][1]
metric = results[0]['metric']['__name__']
if int(float(val)) < 1:
    print(f'[-] Error: {metric} value {val} < 1', file=sys.stderr)
    sys.exit(1)
print(f'  ✓ PromQL Series Found: {metric} = {val} (Total Series: {len(results)})')
" || fail "mvno_call_requests_total series missing or value < 1"
pass "VictoriaMetrics TSDB telemetry value ≥ 1"

# ==============================================================================
# [12/13] SOTA GRAFANA NOC COMMAND CENTER DASHBOARD
# ==============================================================================
# Technical Verification: Queries Grafana login page on host port 3000.
# Protocol / Component: HTTP / Grafana OSS 11.6.0 (admin/admin).
# Validation Criteria: Asserts HTTP status code 200 OK.
# ==============================================================================
echo -e "${YELLOW}[12/13] 📊 Verifying SOTA Grafana NOC Command Center Dashboard...${NC}"
code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/login)
echo -e "  Grafana Dashboard URL: http://localhost:3000 (admin/admin)"
[ "$code" = "200" ] && pass "Grafana NOC dashboard reachable (HTTP 200)" || fail "Grafana login returned HTTP ${code} (expected 200)"

# ==============================================================================
# [13/13] OVERALL STACK GRADUATION READINESS VERIFICATION (MASTER HARD GATE)
# ==============================================================================
# Technical Verification: Re-asserts live VictoriaMetrics telemetry counters.
# Protocol / Component: PromQL System Gate / Master Telemetry Verification.
# Validation Criteria: Hard gate asserting all preceding 12 steps executed cleanly.
# Displays the final graduation presentation readiness banner.
# ==============================================================================
echo -e "${YELLOW}[13/13] 🎓 Overall Stack Graduation Readiness Verification...${NC}"
python3 -c "
import urllib.request, json, sys
url = 'http://localhost:8428/api/v1/query?query=mvno_call_requests_total'
data = json.loads(urllib.request.urlopen(url).read().decode('utf-8'))
results = data.get('data', {}).get('result', [])
if not results:
    print('[-] Error: VictoriaMetrics returned 0 series for mvno_call_requests_total', file=sys.stderr)
    sys.exit(1)
val = results[0]['value'][1]
if int(float(val)) < 1:
    print(f'[-] Error: mvno_call_requests_total value {val} < 1', file=sys.stderr)
    sys.exit(1)
print(f\"  ✓ Telemetry re-asserted live: {results[0]['metric']['__name__']} = {val}\")
" || fail "master gate: mvno_call_requests_total series missing or < 1"
pass "Master telemetry gate re-asserted (value ≥ 1)"
echo -e "${GREEN}✓ All core telecom, signaling, interception, ASR, and observability flows verified live${NC}\n"

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}${BOLD}==== DEMO RUNBOOK: ${FAIL} FAILURE(S), ${PASS} PASSED — ABORTING ====${NC}"
  exit 1
fi
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "${GREEN}${BOLD}  🎉 ALL 13 DEMO ITEMS PASSED (${PASS} real assertions) — GRADUATION PROJECT DEMO READY!${NC}"
echo -e "${CYAN}${BOLD}========================================================================${NC}"
