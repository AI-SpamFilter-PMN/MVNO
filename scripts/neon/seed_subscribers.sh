#!/usr/bin/env bash
# ==============================================================================
# seed_subscribers.sh — Seeds standard demo subscribers into NeonDB local mirror
# ==============================================================================
# Inserts standard MVNO subscriber records into `subscribers` table:
#   - Enables calls.source_subscriber_id -> subscribers.imsi FK linkage
#   - Row-only contract compliant (zero DDL/schema change)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

echo "── Seeding demo subscribers into local NeonDB mirror (mvno-neon-local) ──"

if ! podman ps --format '{{.Names}}' | grep -qx mvno-neon-local; then
    echo "  ⚠ mvno-neon-local is not running. Please start it via 'make up' or podman compose."
    exit 0
fi

SQL="
INSERT INTO subscribers (msisdn, imsi, display_name, status)
VALUES
    ('15553332211', '001010000000001', 'Laptop UE 1 (Initiator)', 'ACTIVE'),
    ('15559998888', '001010000000003', 'Laptop UE 2 (Callee)', 'ACTIVE'),
    ('15551234567', '001010000000002', 'Android Handset (Linphone)', 'ACTIVE'),
    ('15554443322', '001010000000004', '2G MS 1 (Osmocom)', 'ACTIVE'),
    ('15557778888', '001010000000005', '2G MS 2 (Osmocom)', 'ACTIVE')
ON CONFLICT (msisdn) DO UPDATE SET
    imsi = EXCLUDED.imsi,
    display_name = EXCLUDED.display_name,
    status = EXCLUDED.status;
"

podman exec -i mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=1 -c "${SQL}"
echo "  ✓ Demo subscribers successfully seeded into local NeonDB mirror."
podman exec -i mvno-neon-local psql -U mvno -d neondb -c "SELECT id, msisdn, imsi, display_name, status FROM subscribers;"
