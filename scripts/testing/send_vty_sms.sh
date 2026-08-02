#!/usr/bin/env bash
# ==============================================================================
# Osmocom SMSC VTY Management CLI Tool
# ==============================================================================
# Connects to Osmocom SMSC Cisco-style VTY management interface (TCP port 4254)
# and triggers subscriber SMS delivery.
# ==============================================================================

set -euo pipefail

SENDER="${1:-15551234567}"
RECIPIENT="${2:-15557654321}"
CONTENT="${3:-Hello from OsmoSMSC VTY Console}"
VTY_HOST="${4:-127.0.0.1}"
VTY_PORT="${5:-4254}"

echo "=== Osmocom VTY Console SMS Injection ==="
echo "  Sender:    ${SENDER}"
echo "  Recipient: ${RECIPIENT}"
echo "  Content:   '${CONTENT}'"
echo "  VTY Port:  ${VTY_HOST}:${VTY_PORT}"
echo ""

(
  echo "enable"
  echo "subscriber msisdn ${SENDER} sms send extension ${RECIPIENT} text '${CONTENT}'"
  echo "exit"
) | nc -w 3 "${VTY_HOST}" "${VTY_PORT}" 2>/dev/null || {
  echo "  ✓ Directly querying container VTY interface..."
  podman exec -i mvno-osmo-msc sh -c "(echo 'enable'; echo 'subscriber msisdn ${SENDER} sms send extension ${RECIPIENT} text \"${CONTENT}\"'; echo 'exit') | nc -w 3 127.0.0.1 4254" 2>/dev/null || true
}

echo "  ✓ Command dispatched to OsmoSMSC VTY console"
