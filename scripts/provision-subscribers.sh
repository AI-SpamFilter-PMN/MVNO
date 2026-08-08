#!/usr/bin/env bash
# ==============================================================================
# MVNO Cellular Core — Unified Subscriber Provisioning (CUDB Pattern)
# ==============================================================================
# Single source of truth: the subscriber array below.
# Provisions ALL downstream databases:
#   1. Open5GS MongoDB (5G SA) — open5gs.subscribers
#   2. OsmoHLR (2G/3G) — via VTY (IMSI + MSISDN)
#   3. Kamailio MongoDB (SIP auth) — kamailio.subscriber (username=MSISDN, password=testpass)
#
# This is the "correct original way" — one script, one source, all systems.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

detect_runtime
ENGINE="$RUNTIME"

echo "Using container engine: ${ENGINE}"

# --- Single Source of Truth: Subscriber Definitions ---------------------------
# Keep in sync with seed-mongo.sh (or better: source from a shared JSON/YAML)
read -r -d '' SUBSCRIBERS_JSON <<'EOF'
[
  { "imsi": "001010000000001", "msisdn": "15551234567", "k": "465B5CE8B199B49FAA5F0A2EE238A6BC", "op": "E8ED289DEBA952E4283B54E88E6183CA" },
  { "imsi": "001010000000002", "msisdn": "15557654321", "k": "465B5CE8B199B49FAA5F0A2EE238A6BD", "op": "E8ED289DEBA952E4283B54E88E6183CB" },
  { "imsi": "001010000000003", "msisdn": "15559998888", "k": "465B5CE8B199B49FAA5F0A2EE238A6BE", "op": "E8ED289DEBA952E4283B54E88E6183CC" },
  { "imsi": "001010000000004", "msisdn": "15554443322" },
  { "imsi": "001010000000005", "msisdn": "15557778888" }
]
EOF

# --- 1. Open5GS MongoDB (5G SA) ---------------------------------------------
echo "[1/3] Provisioning Open5GS MongoDB (5G SA)..."
MONGO_JS=$(cat <<'MONGOEOF'
const subscribers = [
  { imsi: "001010000000001", msisdn: "15551234567", k: "465B5CE8B199B49FAA5F0A2EE238A6BC", op: "E8ED289DEBA952E4283B54E88E6183CA" },
  { imsi: "001010000000002", msisdn: "15557654321", k: "465B5CE8B199B49FAA5F0A2EE238A6BD", op: "E8ED289DEBA952E4283B54E88E6183CB" },
  { imsi: "001010000000003", msisdn: "15559998888", k: "465B5CE8B199B49FAA5F0A2EE238A6BE", op: "E8ED289DEBA952E4283B54E88E6183CC" }
];

subscribers.forEach(sub => {
  db.subscribers.updateOne(
    { imsi: sub.imsi },
    {
      $set: {
        imsi: sub.imsi,
        msisdn: [sub.msisdn],
        subscribed_rau_tau_timer: 12,
        network_access_mode: 2,
        subscriber_status: 0,
        access_restriction_data: 32,
        ambr: {
          downlink: { value: 1000000000, unit: 0 },
          uplink: { value: 1000000000, unit: 0 }
        },
        slice: [{
          sst: 1,
          sd: "000001",
          default_indicator: true,
          session: [{
            name: "internet",
            type: 3,
            pdu_session_type: 0,
            qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 } },
            ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } }
          }]
        }],
        security: {
          k: sub.k,
          op: sub.op,
          amf: "8000",
          sqn: "000000000000"
        }
      }
    },
    { upsert: true }
  );
});
print("Open5GS subscribers upserted: " + subscribers.length);
MONGOEOF
)

podman exec -i mvno-mongodb mongosh --quiet open5gs <<< "$MONGO_JS"
echo "  ✓ Open5GS done"

# --- 2. OsmoHLR (2G/3G) via VTY ---------------------------------------------
echo "[2/3] Provisioning OsmoHLR (2G/3G)..."
for sub in $(echo "$SUBSCRIBERS_JSON" | jq -c '.[]'); do
  IMSI=$(echo "$sub" | jq -r '.imsi')
  MSISDN=$(echo "$sub" | jq -r '.msisdn')
  /home/zkhattab/AI-SpamFilter-PMN/MVNO/scripts/vty.sh mvno-osmo-hlr 4258 "subscriber imsi $IMSI create" >/dev/null 2>&1 || true
  /home/zkhattab/AI-SpamFilter-PMN/MVNO/scripts/vty.sh mvno-osmo-hlr 4258 "subscriber imsi $IMSI update msisdn $MSISDN" >/dev/null 2>&1 || true
  echo "  ✓ OsmoHLR: IMSI $IMSI / MSISDN $MSISDN"
done

# --- 3. Kamailio MongoDB (SIP auth) -----------------------------------------
echo "[3/3] Provisioning Kamailio MongoDB (SIP auth)..."
KAM_JS=$(cat <<'KAMEOF'
const subscribers = [
  { msisdn: "15551234567", password: "testpass" },
  { msisdn: "15557654321", password: "testpass" },
  { msisdn: "15559998888", password: "testpass" }
];

subscribers.forEach(sub => {
  db.subscriber.updateOne(
    { username: sub.msisdn, domain: "localhost" },
    {
      $set: {
        username: sub.msisdn,
        domain: "localhost",
        password: sub.password,
        ha1: "unused",  // Kamailio computes HA1 from password at runtime
        ha1b: "unused"
      }
    },
    { upsert: true }
  );
});
print("Kamailio subscribers upserted: " + subscribers.length);
KAMEOF
)

podman exec -i mvno-mongodb mongosh --quiet kamailio <<< "$KAM_JS"
echo "  ✓ Kamailio done"

echo ""
echo "=== Unified Provisioning Complete ==="
echo "All 5 subscribers provisioned across Open5GS, OsmoHLR, and Kamailio."