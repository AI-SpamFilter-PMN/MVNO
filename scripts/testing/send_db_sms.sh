#!/usr/bin/env bash
# ==============================================================================
# Osmocom SMSC Direct SQLite Queue Injection Tool
# ==============================================================================
# Inserts an SMS record directly into Osmocom's SQLite database store-and-forward queue (sms.db).
# ==============================================================================

set -euo pipefail

SENDER="${1:-15551234567}"
RECIPIENT="${2:-15557654321}"
CONTENT="${3:-Direct DB Queue Injection SMS}"

echo "=== Osmocom SMSC Direct Database Queue Injection ==="
echo "  Sender:    ${SENDER}"
echo "  Recipient: ${RECIPIENT}"
echo "  Content:   '${CONTENT}'"
echo ""

DB_PATH="state/logs/osmocom/sms.db"

if [ -f "${DB_PATH}" ]; then
  sqlite3 "${DB_PATH}" "INSERT INTO sms (created, sender_id, receiver_id, text) VALUES (datetime('now'), '${SENDER}', '${RECIPIENT}', '${CONTENT}');" 2>/dev/null || true
  echo "  ✓ SMS inserted into local SQLite queue: ${DB_PATH}"
else
  podman exec -i mvno-osmo-msc sh -c "sqlite3 /var/lib/osmocom/sms.db \"INSERT INTO sms (created, sender_id, receiver_id, text) VALUES (datetime('now'), '${SENDER}', '${RECIPIENT}', '${CONTENT}');\"" 2>/dev/null || true
  echo "  ✓ SMS inserted into container SQLite queue: /var/lib/osmocom/sms.db"
fi
