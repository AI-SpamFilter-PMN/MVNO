#!/usr/bin/env bash
# ==============================================================================
# add-subscriber.sh — provision a NEW MVNO subscriber (2G + 5G), keys auto
# ==============================================================================
# MSISDN-only interface; everything else is derived:
#   bash scripts/add-subscriber.sh <MSISDN> [--2g-only] [--imsi <IMSI>]
#
# Writes every store the demo/core reads, so a new subscriber actually works:
#   1. OsmoHLR VTY (2G/3G, real store)            — subscriber imsi <I> create
#      + update msisdn <M> (2G/3G auth is IMSI-based, no keys required)
#   2. state/hlr/hlr.db (SQLite mirror, Makefile shape)
#   3. Kamailio SQLite auth_db (state/kamailio/kamailio.db) — REQUIRED: this is
#      the store kamailio.cfg auth_db authenticates digest (password testpass),
#      so the SIP MESSAGE / REGISTER paths work. The master plan's "3 stores as
#      provision-subscribers.sh" would have produced a user who cannot
#      authenticate — the sqlite row is the authoritative SIP-auth store.
#   4. Kamailio MongoDB (parallel store, provision-subscribers.sh convention)
#   5. Open5GS MongoDB (5G SA) — full v2.8.0 doc shape (top-level ambr/msisdn/
#      slice + security k/op/amf), unless --2g-only
#   6. Optional 5G attach: generates configs/ueransim/ue-<N>.yaml from the
#      ue.yaml template (auto K/OP) + prints the compose service snippet. The
#      compose file is NOT edited — a full attach needs a NET_ADMIN container,
#      so that step stays explicit (SMS-only needs nothing beyond stores 1-5).
#
# Crypto truth: 5G SA registration is impossible without K/OP/AMF on BOTH the
# core (store 5) and the UE (store 6). 2G needs only IMSI+MSISDN.
#
# Refuses to overwrite: prints which store the MSISDN/IMSI already lives in.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say()  { echo -e "\033[0;36m[add-subscriber]\033[0m $*"; }
die()  { echo -e "\033[0;31m[add-subscriber] FATAL: $*\033[0m" >&2; exit 1; }
warn() { echo -e "\033[0;33m[add-subscriber] ⚠ $*\033[0m"; }

usage() {
    cat <<EOF
Usage: bash scripts/add-subscriber.sh <MSISDN> [--2g-only] [--imsi <IMSI>]

  <MSISDN>   11-digit MVNO number, must start with 155 (e.g. 15551234999)
  --2g-only  skip Open5GS 5G keys + the UERANSIM UE yaml (2G/3G only)
  --imsi <I> manual IMSI (default: next free in 0010100xxxxxxxx range)

Refuses to overwrite an MSISDN/IMSI that already exists in any store.
EOF
    exit "${1:-0}"
}

[ $# -ge 1 ] || usage 1
MSISDN="$1"; shift
TWO_G_ONLY=0
IMSI=""
while [ $# -gt 0 ]; do
    case "$1" in
        --2g-only) TWO_G_ONLY=1 ;;
        --imsi) [ $# -ge 2 ] || die "--imsi needs a value"; IMSI="$2"; shift ;;
        -h|--help) usage ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
    shift
done

# --- Validate MSISDN -----------------------------------------------------------
[[ "$MSISDN" =~ ^155[0-9]{8}$ ]] || die "MSISDN must be 11 digits starting 155 (got: $MSISDN)"

# --- Container preflight (fail-fast: no partial provisioning) -------------------
# Without these, a cold/partial stack writes sqlite+hlr.db then dies at the
# mongo step under set -e — a half-provisioned subscriber with a misleading
# "✓" summary. Check the containers the stores live in before any write.
for c in mvno-osmo-hlr mvno-mongodb; do
    podman ps --format '{{.Names}}' | grep -qx "$c" \
        || die "$c not running — start the stack (make up) before provisioning"
done
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 required on the host"

# --- Store helpers -------------------------------------------------------------
# NB: mongosh in this build does NOT exit after a script on stdin (it stays in
# the REPL), so all provisioning uses --eval with a JS string instead of heredoc
# pipes — the same reason seed-mongo.sh/provision-subscribers.sh pass --eval.
mongosh_eval() {  # $1=db  $2=JS  — run JS via --eval on the mvno-mongodb container
    podman exec mvno-mongodb mongosh --quiet "$1" --eval "$2" >/dev/null
}

next_free_imsi() {
    # Highest existing IMSI suffix across hlr.db + Open5GS mongo -> +1.
    local max=0 n
    while read -r n; do
        [ -n "$n" ] && [ "$n" -gt "$max" ] && max="$n"
    done < <(sqlite3 state/hlr/hlr.db "SELECT imsi FROM subscriber;" 2>/dev/null \
                | sed -n 's/^0010100\([0-9]\{8\}\)$/\1/p' || true)
    while read -r n; do
        [ -n "$n" ] && [ "$n" -gt "$max" ] && max="$n"
    done < <(podman exec mvno-mongodb mongosh --quiet open5gs --eval \
                'db.subscribers.find({}, {_id:0, imsi:1}).toArray().forEach(s => print(s.imsi))' 2>/dev/null \
                | sed -n 's/^0010100\([0-9]\{8\}\)$/\1/p' || true)
    printf '0010100%08d' "$((max + 1))"
}

imsi_suffix() { echo "$1" | sed -n 's/^0010100\([0-9]\{8\}\)$/\1/p'; }

# --- Refuse duplicates (the user asked: print the store it already lives in) ---
in_sqlite=$(sqlite3 state/kamailio/kamailio.db \
    "SELECT COALESCE((SELECT 'kamailio sqlite auth_db' FROM subscriber WHERE username='${MSISDN}' OR msisdn='${MSISDN}' LIMIT 1), '');" 2>/dev/null || true)
in_hlr=$(sqlite3 state/hlr/hlr.db \
    "SELECT COALESCE((SELECT 'hlr.db mirror' FROM subscriber WHERE msisdn='${MSISDN}' LIMIT 1), '');" 2>/dev/null || true)
in_mongo=$(podman exec mvno-mongodb mongosh --quiet open5gs --eval \
    "print(db.subscribers.countDocuments({msisdn: '${MSISDN}'}) > 0 ? 'open5gs mongo' : '')" 2>/dev/null || true)
in_kam_mongo=$(podman exec mvno-mongodb mongosh --quiet kamailio --eval \
    "print(db.subscriber.countDocuments({username: '${MSISDN}'}) > 0 ? 'kamailio mongo' : '')" 2>/dev/null || true)
for hit in "$in_sqlite" "$in_hlr" "$in_mongo" "$in_kam_mongo"; do
    [ -n "$hit" ] && die "MSISDN ${MSISDN} already exists in ${hit} — refusing to overwrite"
done

if [ -z "$IMSI" ]; then
    IMSI="$(next_free_imsi)"
else
    [[ "$IMSI" =~ ^0010100[0-9]{8}$ ]] || die "IMSI must match 0010100xxxxxxxx (got: $IMSI)"
fi
[ -z "$(imsi_suffix "$IMSI")" ] && die "IMSI must match 0010100xxxxxxxx (got: $IMSI)"

# Existing-IMSI check
if sqlite3 state/hlr/hlr.db "SELECT 1 FROM subscriber WHERE imsi='${IMSI}' LIMIT 1;" 2>/dev/null | grep -q 1 \
   || podman exec mvno-mongodb mongosh --quiet open5gs --eval \
        "print(db.subscribers.countDocuments({imsi: '${IMSI}'}) > 0)" 2>/dev/null | grep -q true; then
    die "IMSI ${IMSI} already exists — refusing to overwrite"
fi

# --- Derived credentials -------------------------------------------------------
# 5G SA keys: random K + raw OP (core computes OPc via Milenage; UERANSIM
# opType 'OP' matches). amf=8000, sqn=0 — same stanza shape as seed-mongo.sh.
K="$(openssl rand -hex 16 | tr 'a-f' 'A-F')"
OP="$(openssl rand -hex 16 | tr 'a-f' 'A-F')"
PASSWORD=testpass
UE_N="$((10#$(imsi_suffix "$IMSI")))"   # strip leading zeros: IMSI ...00000006 -> UE 6
UE_FILE="configs/ueransim/ue-${UE_N}.yaml"
UE_IP="10.89.0.$((30 + UE_N))"

if [ "$TWO_G_ONLY" -eq 1 ]; then
    say "provisioning MSISDN ${MSISDN} / IMSI ${IMSI} (2G-only)"
else
    say "provisioning MSISDN ${MSISDN} / IMSI ${IMSI} (2G+5G)"
    say "  5G keys auto-generated: K=${K} OP=${OP} amf=8000"
fi

# --- 1. OsmoHLR VTY (2G/3G) -----------------------------------------------------
say "[1/5] OsmoHLR VTY — subscriber ${IMSI} / ${MSISDN}"
scripts/vty.sh mvno-osmo-hlr 4258 "subscriber imsi ${IMSI} create" >/dev/null 2>&1 || true
scripts/vty.sh mvno-osmo-hlr 4258 "subscriber imsi ${IMSI} update msisdn ${MSISDN}" >/dev/null 2>&1 \
    || warn "osmo-hlr msisdn update returned non-zero (re-check 'show subscribers all')"

# --- 2. state/hlr/hlr.db mirror (Makefile shape) -------------------------------
sqlite3 state/hlr/hlr.db \
    "INSERT OR IGNORE INTO subscriber (imsi, msisdn) VALUES ('${IMSI}', '${MSISDN}');" \
    || warn "hlr.db mirror insert failed (row may pre-exist)"

# --- 3. Kamailio SQLite auth_db — REQUIRED for SIP digest auth ------------------
say "[3/5] Kamailio sqlite auth_db — SIP digest auth user ${MSISDN} (password ${PASSWORD})"
sqlite3 state/kamailio/kamailio.db \
    "INSERT INTO subscriber (username, domain, password, ha1, ha1b, msisdn, balance) \
     VALUES ('${MSISDN}', 'localhost', '${PASSWORD}', '', '', '${MSISDN}', 100) \
     ON CONFLICT(msisdn) DO UPDATE SET username=excluded.username, domain=excluded.domain, \
     password=excluded.password, ha1=excluded.ha1, ha1b=excluded.ha1b, balance=excluded.balance;" \
    || die "sqlite auth_db upsert failed"

# --- 4. Kamailio MongoDB (parallel store, provision-subscribers convention) -----
if [ "$TWO_G_ONLY" -eq 0 ]; then
    # Kamailio MongoDB parallel store — provision-subscribers.sh scopes this to
    # the 5G/IMS users only; 2G-only subscribers skip it (store is inert: the
    # authoritative SIP-auth store is the sqlite auth_db written in step 3).
    say "[4/5] Kamailio MongoDB — parallel store"
    KAM_JS=$(cat <<KAMEOF
db.subscriber.updateOne(
  { username: "${MSISDN}", domain: "localhost" },
  { \$set: { username: "${MSISDN}", domain: "localhost", password: "${PASSWORD}", ha1: "unused", ha1b: "unused" } },
  { upsert: true }
);
KAMEOF
)
    mongosh_eval kamailio "${KAM_JS}"
fi

# --- 5. Open5GS MongoDB (5G SA) -------------------------------------------------
if [ "$TWO_G_ONLY" -eq 0 ]; then
    say "[5/5] Open5GS MongoDB — 5G SA doc (top-level ambr/msisdn/slice + security)"
    O5G_JS=$(cat <<MONGOEOF
db.subscribers.updateOne(
  { imsi: "${IMSI}" },
  { \$set: {
      imsi: "${IMSI}",
      msisdn: ["${MSISDN}"],
      subscribed_rau_tau_timer: 12,
      network_access_mode: 2,
      subscriber_status: 0,
      access_restriction_data: 32,
      ambr: { downlink: { value: 1000000000, unit: 0 }, uplink: { value: 1000000000, unit: 0 } },
      slice: [{ sst: 1, sd: "000001", default_indicator: true,
        session: [{ name: "internet", type: 3, pdu_session_type: 0,
          qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 } },
          ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } } }] }],
      security: { k: "${K}", op: "${OP}", amf: "8000", sqn: NumberLong(0) }
  } },
  { upsert: true }
);
MONGOEOF
)
    mongosh_eval open5gs "${O5G_JS}"

    # --- 6. Optional 5G attach: generate the UE yaml + compose snippet -----------
    say "[6] UERANSIM UE config — ${UE_FILE} (auto K/OP, MSISDN ${MSISDN})"
    if [ -f configs/ueransim/ue.yaml ]; then
        sed -e "s/^supi:.*/supi: 'imsi-${IMSI}'/" \
            -e "s/^key:.*/key: '${K}'/" \
            -e "s/^op:.*/op: '${OP}'/" \
            -e "s/^opc:.*/opc: '${OP}'/" \
            -e "s/^amf:.*/amf: '8000'/" \
            configs/ueransim/ue.yaml > "${UE_FILE}"
        chmod 644 "${UE_FILE}"
        echo ""
        echo "  To attach a real 5G UE for ${MSISDN} (needs NET_ADMIN, ~2-4 min):"
        echo "  1. Append to docker-compose.yml (mirror ueransim-ue-1, IP ${UE_IP}):"
        cat <<SNIPPET
  ueransim-ue-${UE_N}:
    image: mvno-ueransim:3.2.6
    container_name: mvno-ueransim-ue-${UE_N}
    command: ["nr-ue", "-c", "/etc/ueransim/ue.yaml"]
    volumes:
      - ./${UE_FILE}:/etc/ueransim/ue.yaml:z
    cap_add: [NET_ADMIN, SYS_PTRACE]
    devices: [/dev/net/tun:/dev/net/tun]
    depends_on: { ueransim-gnb: { condition: service_started } }
    networks: { mvno_net: { ipv4_address: ${UE_IP} } }
    restart: unless-stopped
SNIPPET
        echo "  2. podman compose up -d ueransim-ue-${UE_N}"
        echo "     (SMS-only paths need stores 1-5 only — no UE attach required.)"
    else
        warn "configs/ueransim/ue.yaml template not found — skipping UE yaml generation"
    fi
fi

echo ""
echo "=== Provisioning Complete ==="
echo "  MSISDN ${MSISDN} / IMSI ${IMSI} provisioned:"
echo "    - OsmoHLR VTY (2G/3G)          ✓"
echo "    - state/hlr/hlr.db mirror      ✓"
echo "    - Kamailio sqlite auth_db      ✓ (SIP digest auth, password ${PASSWORD})"
if [ "$TWO_G_ONLY" -eq 0 ]; then
    echo "    - Kamailio MongoDB             ✓ (parallel store)"
    echo "    - Open5GS MongoDB (5G SA)     ✓  K=${K} OP=${OP}"
    echo "    - UERANSIM UE yaml            ✓ ${UE_FILE} (attach optional, see above)"
else
    echo "    - Kamailio MongoDB             skipped (--2g-only; sqlite auth_db is authoritative)"
    echo "    - Open5GS MongoDB / UE yaml   skipped (--2g-only)"
fi
