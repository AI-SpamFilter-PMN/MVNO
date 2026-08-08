#!/usr/bin/env bash
# ==============================================================================
# Real-Time Panel Interception — one-command live spam-block demo
# ==============================================================================
# A panel-triggered send: an arbitrary message is submitted through the SAME
# interception path the demo certifies (telecom-api → ai-filter → verdict),
# then the presenter immediately shows the VictoriaLogs row + the
# mvno_sms_blocked_total counter moving — all from one command.
#
# FLOW:   send_rest_sms.sh <spammer> <target> "<text>"
#         └─ POST /api/v1/intercept/sms (X-API-Key) → ai-filter verdict
#         └─ if blocked: counter++, kamailio logs "SMS BLOCKED ... (jansson
#            allow=false)" → vector → VictoriaLogs (queryable live)
#
# The ai-filter mock blocks deterministically on the E2E-BLOCK marker. The
# default content below carries it, so the panel ALWAYS sees a live block;
# pass custom text without the marker to show an allow (clean) verdict.
#
# Usage:
#   bash scripts/demo/intercept_live.sh                          # default block
#   bash scripts/demo/intercept_live.sh "15551234567" "15557654321" "text"
# Exit: 0 always (verdict printed either way — the demo shows BOTH paths)
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

SENDER="${1:-15551234567}"
RECIPIENT="${2:-15557654321}"
CONTENT="${3:-Award-winning offer, reply now — E2E-BLOCK panel demo}"

echo "========================================================================"
echo " ⚡ REAL-TIME PANEL INTERCEPTION (live, one command)"
echo "========================================================================"
echo "  sender:    ${SENDER}"
echo "  recipient: ${RECIPIENT}"
echo "  content:   '${CONTENT}'"
echo ""

# --- 1. the interception call itself ------------------------------------------
# Counter source: the actuator /prometheus endpoint (IMMEDIATE — the same
# source e2e_runbook.sh reads). VictoriaMetrics lags by the vmagent scrape
# interval (15-30 s), which would show a stale "0 → 0" right after a block.
BEFORE="$(curl -s http://localhost:8080/actuator/prometheus \
  | awk '/^mvno_sms_blocked_total /{print $2}' | head -1)"
BEFORE="${BEFORE:-0}"
RESPONSE="$(bash scripts/testing/send_rest_sms.sh "${SENDER}" "${RECIPIENT}" "${CONTENT}" \
  | grep -E 'allow|reason' || true)"
echo "  verdict:  ${RESPONSE:-<no verdict — api unreachable>}"
echo ""

# --- 2. show the counter moving (blocked marker only) -------------------------
if printf '%s' "${RESPONSE}" | grep -q '"allow": *false'; then
  AFTER="$(curl -s http://localhost:8080/actuator/prometheus \
    | awk '/^mvno_sms_blocked_total /{print $2}' | head -1)"
  AFTER="${AFTER:-?}"
  echo "  📈 mvno_sms_blocked_total (actuator, immediate): ${BEFORE} → ${AFTER} (blocked)"
  echo ""

  # --- 3. the VictoriaLogs row appears live ------------------------------------
  echo "  🔍 VictoriaLogs row (this block, live):"
  curl -s "http://127.0.0.1:9428/select/logsql/query" \
    --data-urlencode '_time=now-5m' \
    --data-urlencode 'query="SMS BLOCKED BY MVNO INTERCEPTION"' \
    | grep -o '"container":"mvno-kamailio"' | head -1 | sed 's/^/     /'
  curl -s "http://127.0.0.1:9428/select/logsql/query" \
    --data-urlencode '_time=now-5m' \
    --data-urlencode 'query="SMS BLOCKED BY MVNO INTERCEPTION"' \
    | grep -oE '"SMS BLOCKED[^"]*"' | head -1 | sed 's/^/     /'
  echo "     (full row: curl 'http://127.0.0.1:9428/select/logsql/query' \\"
  echo "      --data-urlencode '_time=now-5m' \\"
  echo "      --data-urlencode 'query=\"SMS BLOCKED BY MVNO INTERCEPTION\"')"
else
  echo "  ✅ allow=true — clean content path (no block, no VL row, counter flat)"
fi
echo "========================================================================"
exit 0
