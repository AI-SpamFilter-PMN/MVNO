#!/usr/bin/env bash
# ==============================================================================
# MVNO Cellular Core — Open5GS MongoDB 5G SA Subscriber Seeding Script
# ==============================================================================
# Upserts 3 UERANSIM 5G SA UE subscribers into MongoDB collection `open5gs.subscribers`.
#
# REQUIRED v2.8.0 LEGACY-SCHEMA FIELDS (lib/dbi/subscription.c, src/udr/nudr-handler.c):
#   The Open5GS 2.x DBI layer parses the FLAT legacy document ONLY (there is no
#   schema_version gate and no OpenAPI `accessAndMobilitySubscriptionData`
#   parsing in lib/dbi) and uses strict BSON_ITER_HOLDS_INT32 accessors, so:
#   - TOP-LEVEL `ambr` (UE-AMBR) is MANDATORY: UDR hard-fails
#     `[supi] No UE-AMBR` (nudr-handler.c:1321) -> UDM -> Registration reject
#     [7] if missing. Value must fit int32 (use NumberInt/explicit small ints).
#   - TOP-LEVEL `msisdn` array is MANDATORY for GPSI (AccessAndMobility
#     SubscriptionData.gpsis); without it UDM returns no gpsis.
#   - slice[].sst / session[].type / qos.index / qos.arp.* / session ambr
#     value+unit must be int32-typed (HOLDS_INT32 guards silently skip doubles).
#   This document shape was reverse-engineered from the working warm-state
#   subscriber doc (see docs/ISSUES.md true-cold UDR UE-AMBR writeup) and
#   matches `open5gs-dbctl add` defaults (1 Gbps AMBR, unit 0).
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

# Source the shared runtime-detection helper (Goal-2 right-sizing).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

detect_runtime
ENGINE="$RUNTIME"

echo "Using container engine: ${ENGINE}"

# Bounded mongodb-readiness poll: seed-mongo execs into the RUNNING container,
# so a cold bootstrap (make bootstrap / deploy.sh) can race mongod's boot. Wait
# until mongosh answers a ping (up to ~60s) before attempting the upserts.
readiness_ok=0
for i in $(seq 1 20); do
    if ${ENGINE} exec -i mvno-mongodb mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q '^1$'; then
        readiness_ok=1
        break
    fi
    sleep 3
done
if [ "${readiness_ok}" -ne 1 ]; then
    echo "ERROR: mvno-mongodb not accepting connections after 60s — cannot seed subscribers" >&2
    echo "       check the container: podman logs mvno-mongodb" >&2
    exit 1
fi

echo "mongodb ready — seeding 5G subscribers"

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
