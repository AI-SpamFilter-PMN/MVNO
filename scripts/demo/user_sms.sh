#!/usr/bin/env bash
# ==============================================================================
# user_sms.sh — USER-DRIVEN live SMS demo (dynamic content, not auto test)
# ------------------------------------------------------------------------------
# Lets the OPERATOR type a custom SMS body (or a scam phrase) and pick any
# MVNO flow (2G->2G, 2G->5G, 5G->2G, 5G->5G, AI-BLOCK-40545) and a source
# sender. The message is injected via the Interception Gateway REST API, so the
# real balance / EIR / AI-Spam pipeline evaluates the LIVE user text.
#
#   bash scripts/demo/user_sms.sh "<body>" [flow] [sender] [recipient]
#
# Flows (default 2g2g):
#   user-sms-2g-2g  2G->2G   (15557778888 -> 15554443322, SMSC direct)
#   user-sms-2g-5g  2G->5G   (15554443322 -> 15551234567, SMSC->SIP relay)
#   user-sms-5g-2g  5G->2G   (15551234567 -> 15554443322, bridge->SMPP)
#   user-sms-5g-5g  5G->5G   (15551234567 -> 15557654321, Kamailio twin)
#   user-sms-ai     5G->5G AI-BLOCK (any 15557654321 recipient, no delivery)
#
# Reuses scripts/testing/send_rest_sms.sh (the REST primitive) — no new send
# logic. Fail-open + non-blocking by design: a scam verdict rows a review FLAG
# (mvno.vosk.scamflag), it never hard-drops the contained demo.
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SEND="${REPO_ROOT}/scripts/testing/send_rest_sms.sh"

# --- flow -> (sender, recipient) mapping (canonical MSISDNs, single source) ---
# 2G direct via SMSC; 5G via SIP/bridge; AI uses the zero-balance 2G recipient 15557654321
flow_sender()  { case "$1" in 2g2g) echo 15557778888;; 2g5g) echo 15554443322;; 5g2g) echo 15551234567;; 5g5g|ai) echo 15551234567;; *) echo 15557778888;; esac; }
flow_recipient(){ case "$1" in 2g2g) echo 15554443322;; 2g5g) echo 15551234567;; 5g2g) echo 15554443322;; 5g5g) echo 15557654321;; ai) echo 15557654321;; *) echo 15554443322;; esac; }

# --- resolve live/dynamic body (arg or prompt) ---------------------------------
BODY="${1:-}"
FLOW="${2:-2g2g}"
if [ -z "${BODY}" ]; then
    echo "📝 USER-DRIVEN SMS — type your live message below (or paste a scam phrase):"
    echo "   hint: try \"You have won a prize, call us now\" or \"your bank account has been blocked\""
    printf '>>> '
    IFS= read -r BODY
    [ -n "${BODY}" ] || { echo "no body given — aborting" >&2; exit 1; }
fi

SENDER="$(flow_sender "${FLOW}")"
RECIPIENT="$(flow_recipient "${FLOW}")"

echo ""
echo "=============================================="
echo "  USER SMS  (flow=${FLOW})  ${SENDER} -> ${RECIPIENT}"
echo "  BODY: \"${BODY}\""
echo "=============================================="
echo ""

# Smoke-test the gateway is up first (friendlier than a curl 404)
curl -sf -X POST "http://127.0.0.1:8080/api/v1/intercept/sms" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: mvno-demo-key-2026" \
    -d "{\"sender\":\"${SENDER}\",\"recipient\":\"${RECIPIENT}\",\"content\":\"${BODY}\"}" \
    | grep -E 'allow|reason' || {
        echo "❌ gateway submission failed — is mvno-api up? (make up)" >&2
        exit 1
    }

echo ""
echo "✅ USER SMS submitted — watch ${SENDER} -> ${RECIPIENT} delivery / verdict above."