#!/usr/bin/env bash
# ==============================================================================
# MVNO Cellular Core — Open5GS MongoDB 5G SA Subscriber Seeding Script
# ==============================================================================
# Upserts 3 UERANSIM 5G SA UE subscribers into MongoDB collection `open5gs.subscribers`.
#
# Subscriber Credentials & Security Stanzes:
# - UE-1 (imsi-001010000000001 / MSISDN 15551234567): K=465B...8A6BC, OP=E8ED...83CA
# - UE-2 (imsi-001010000000002 / MSISDN 15557654321): K=465B...8A6BD, OP=E8ED...83CB
# - UE-3 (imsi-001010000000003 / MSISDN 15559998888): K=465B...8A6BE, OP=E8ED...83CC
#
# Uses `security.op` (raw OP key) so Open5GS UDM/AUSF computes OPc internally via
# Milenage algorithm, matching UERANSIM `opType: 'OP'`.
# ==============================================================================

set -euo pipefail

# Auto-detect container runtime engine (podman preferred)
if command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
else
    echo "ERROR: Neither podman nor docker found in PATH." >&2
    exit 1
fi

echo "Using container engine: ${ENGINE}"

MONGO_JS=$(cat <<'EOF'
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
        subscribed_rau_tau_timer: 12,
        network_access_mode: 2,
        subscriber_status: 0,
        access_restriction_data: 32,
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
          sqn: NumberLong(0)
        }
      }
    },
    { upsert: true }
  );
  print("Seeded subscriber IMSI: " + sub.imsi + " (MSISDN: " + sub.msisdn + ")");
});
EOF
)

echo "Upserting 3 5G SA UERANSIM subscribers into Open5GS MongoDB..."
${ENGINE} exec -i mvno-mongodb mongosh --quiet open5gs --eval "${MONGO_JS}"
echo "✓ 5G SA Subscriber MongoDB seeding complete."
