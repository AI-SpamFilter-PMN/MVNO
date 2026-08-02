#!/usr/bin/env bash
# ==============================================================================
# Interception Gateway REST API SMS Submission Tool
# ==============================================================================
# Sends SMS payload directly to telecom-api Gateway (http://localhost:8080/api/v1/intercept/sms)
# to evaluate balance, EIR, and AI Spam Filter policies.
# ==============================================================================

set -euo pipefail

SENDER="${1:-15551234567}"
RECIPIENT="${2:-15557654321}"
CONTENT="${3:-Hello from Interception Gateway REST API}"
HOST="${4:-http://localhost:8080}"
API_KEY="${5:-mvno-demo-key-2026}"

echo "=== Interception Gateway REST SMS Submission ==="
echo "  Sender:    ${SENDER}"
echo "  Recipient: ${RECIPIENT}"
echo "  Content:   '${CONTENT}'"
echo "  Target:    ${HOST}/api/v1/intercept/sms"
echo ""

RESPONSE=$(curl -s -X POST "${HOST}/api/v1/intercept/sms" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${API_KEY}" \
  -d "{\"sender\": \"${SENDER}\", \"recipient\": \"${RECIPIENT}\", \"content\": \"${CONTENT}\"}")

echo "Response:"
echo "${RESPONSE}" | grep -E "allow|reason" || echo "${RESPONSE}"
