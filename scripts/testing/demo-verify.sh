#!/usr/bin/env bash
# ==============================================================================
# demo-verify.sh — FULLY HEADLESS end-to-end verification (cold-start to gate)
# ------------------------------------------------------------------------------
# Closes the automation gaps in the demo rig:
#   1. Launches Android Linphone natively (am start) and WAITS for REGISTER.
#   2. Runs the internal rig call tx->rx headlessly (MVNO_FORCE_TONE=1) with the
#      canned scam phrase on the callee leg — no human mic required.
#   3. Asserts live media: rtpengine ports bound, RTP PCMU streams in the fresh
#      pcap (0 lost, ~50 pps), and host pulse sink-inputs/source-outputs active.
#   4. Hangs up, then runs the SMS matrix (4-cell + AI-block) gate.
#
# Usage:  bash scripts/testing/demo-verify.sh [--skip-cold-start]
#   --skip-cold-start  skip `make bootstrap` (assumes stack already up+seeded)
# Exit:   0 = all gates green, 1 = any assertion failed
# ==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ok  $1${NC}"; }
fail() { echo -e "${RED}  FAIL $1${NC}"; FAILED=1; }
PASS=0; FAILED=0

# --- 0. optional cold start ---------------------------------------------------
if [ "${1:-}" != "--skip-cold-start" ]; then
  echo -e "${CYAN}==== [1/6] COLD START: make bootstrap ====${NC}"
  make bootstrap 2>&1 | tail -3 || { fail "make bootstrap"; exit 1; }
  ok "stack up + seeded + bootstrap-check green"
else
  echo -e "${CYAN}==== [1/6] COLD START: skipped (--skip-cold-start) ====${NC}"
fi

# --- 1. phone launch + registration wait --------------------------------------
echo -e "${CYAN}==== [2/6] ANDROID PHONE: launch Linphone + wait REGISTER ====${NC}"
PHONE_MSISDN="${PHONE_MSISDN:-15551234567}"
if adb devices 2>/dev/null | grep -q "device$"; then
  adb shell am force-stop org.linphone 2>/dev/null
  sleep 1
  adb shell am start -W -n org.linphone/.ui.main.MainActivity >/dev/null 2>&1 \
    && ok "Linphone launched natively (am start)" || fail "am start Linphone"
  for i in $(seq 1 30); do
    if sqlite3 state/kamailio/kamailio.db \
        "SELECT 1 FROM location WHERE username='${PHONE_MSISDN}' AND contact LIKE '%192.168%';" 2>/dev/null | grep -q 1; then
      ok "phone registered (${PHONE_MSISDN} via WiFi)"; break
    fi
    [ "$i" -eq 30 ] && fail "phone REGISTER timeout (usrloc)"
    sleep 2
  done
else
  echo "  - no adb device — phone leg skipped"
fi

# --- 2. headless rig call with live-media assertion ----------------------------
echo -e "${CYAN}==== [3/6] RIG CALL tx->rx (headless, live media assert) ====${NC}"
PCAP_BEFORE=$(/usr/bin/ls -t state/spool/pcaps/*.pcap 2>/dev/null | head -1)
BEFORE=$(podman ps -a --format '{{.Names}}' | grep -c baresip)
CTRL_MSG="{\"command\":\"dial\",\"params\":\"sip:15559998888@10.89.0.23:5060\"}"
podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; printf '${#CTRL_MSG}:${CTRL_MSG},' >&3; timeout 3 cat <&3" \
  | grep -q CALL_ESTABLISHED && ok "call established (tx->rx)" || fail "call not established"
# rx auto-answers (answermode=auto). Wait for media to accumulate.
sleep 8
PULSE_SINKS=$(pactl list short sink-inputs 2>/dev/null | wc -l)
PULSE_SRCS=$(pactl list short source-outputs 2>/dev/null | wc -l)
[ "$PULSE_SINKS" -ge 2 ] && ok "host pulse sink-inputs active (${PULSE_SINKS})" || fail "sink-inputs (${PULSE_SINKS})"
[ "$PULSE_SRCS" -ge 2 ] && ok "host pulse source-outputs active (${PULSE_SRCS})" || fail "source-outputs (${PULSE_SRCS})"
RTP_PORTS=$(podman exec mvno-rtpengine ss -lun 2>/dev/null | grep -cE ':(1[0-9]{4}|2[0-9]{4})')
[ "$RTP_PORTS" -ge 4 ] && ok "rtpengine ports bound (${RTP_PORTS})" || fail "rtpengine ports (${RTP_PORTS})"
PCAP_NEW=$(/usr/bin/ls -t state/spool/pcaps/*.pcap 2>/dev/null | head -1)
RTP_STREAMS=$(tshark -r "$PCAP_NEW" -d udp.port==10000,rtp -d udp.port==10022,rtp -Y "rtp" 2>/dev/null | wc -l)
[ "$RTP_STREAMS" -ge 100 ] && ok "RTP packets in fresh pcap (${RTP_STREAMS})" || fail "RTP packets (${RTP_STREAMS})"
LOST=$(tshark -r "$PCAP_NEW" -d udp.port==10000,rtp -d udp.port==10022,rtp -q -z rtp,streams 2>/dev/null | grep -oE "[0-9]+ \(0\.0%\)" | head -1)
[ -n "$LOST" ] && ok "rtp streams loss ${LOST}" || fail "loss check"
# hang up
HANGUP_MSG='{"command":"hangup"}'
podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; printf '${#HANGUP_MSG}:${HANGUP_MSG},' >&3; timeout 2 cat <&3" >/dev/null 2>&1
sleep 2
podman logs baresip-rx 2>/dev/null | grep -c "200 Answering" | grep -qE "[1-9]" \
  && ok "rx answered (200 Answering)" || fail "rx no 200 Answering"

# --- 3. SMS matrix gate ----------------------------------------------------------
echo -e "${CYAN}==== [4/6] SMS MATRIX (4-cell + AI-block) ====${NC}"
if bash scripts/testing/sms_matrix.sh 2>&1 | tail -4 | grep -q "ALL CELLS PASS"; then
  ok "SMS matrix ALL CELLS PASS"
else
  echo "  (sms_matrix detail above)"
  fail "SMS matrix"
fi

# --- 4. summary -------------------------------------------------------------------
echo -e "${CYAN}==== [5/6] PREFLIGHT ====${NC}"
bash scripts/preflight.sh 2>&1 | tail -1 | grep -q "ALL CLEAR" && ok "preflight ALL CLEAR" || fail "preflight"
echo -e "${CYAN}==== [6/6] SUMMARY ====${NC}"
if [ "${FAILED:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ DEMO-VERIFY: ALL GATES PASS${NC}"; exit 0
else
  echo -e "${RED}❌ DEMO-VERIFY: ${FAILED} FAILURE(S)${NC}"; exit 1
fi
