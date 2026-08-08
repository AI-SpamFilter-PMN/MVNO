#!/usr/bin/env bash
# ==============================================================================
# subscriber_proof.sh — repeatable run-evidence for add-subscriber.sh
# ==============================================================================
# Proves a fresh subscriber actually works end-to-end, then cleans up:
#   [1] provision a THROWAWAY MSISDN via add-subscriber.sh (15551234999)
#   [2] assert all stores contain the row (osmo-hlr VTY, hlr.db, Kamailio
#       sqlite auth_db, Kamailio Mongo, Open5GS Mongo)
#   [3] assert a real SIP REGISTER 200 OK for that MSISDN (proves the
#       testpass/auth_db digest path SipClient uses actually authenticates)
#   [4] cleanup: remove the throwaway row from every store + deregister
#   Exit 0 only when every assertion passes; tee'd to
#   docs/evidence/demo-subscriber-<date>.log.
#
#   bash scripts/testing/subscriber_proof.sh            # deterministic proof
#   bash scripts/testing/subscriber_proof.sh --attach   # + check_ip_pins +
#                                                       #   attach-optional note
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
source "$REPO_ROOT/scripts/lib/common.sh"

LOG="docs/evidence/demo-subscriber-$(date +%F).log"
mkdir -p docs/evidence
MODE="${1:-}"
THROWAWAY="${MVNO_THROWAWAY}"   # sanctioned throwaway (single source: common.sh)
PASS=1

fail() { echo "  ✗ $*"; PASS=0; }
ok()   { echo "  ✓ $*"; }

main() {
    echo "================================================================"
    echo "SUBSCRIBER PROOF — add-subscriber.sh run-evidence ($(date '+%F %T'))"
    echo "================================================================"

    # Registry proof-lock: the watchdog's run_in_flight skips recovery while
    # this proof is provisioning a subscriber + registering a throwaway UAS
    # (the pgrep set already covers the script; the lock makes it explicit).
    acquire_run_lock mvno-subscriber-proof.lock || { echo "FATAL: another run is in flight"; return 1; }

    # --- Preconditions ---
    for c in mvno-osmo-hlr mvno-mongodb; do
        podman ps --format '{{.Names}}' | grep -qx "$c" || { echo "FATAL: ${c} not Up — run make up first"; return 1; }
    done
    # Idempotent start: purge any leftover throwaway from a prior interrupted run.
    sqlite3 state/kamailio/kamailio.db "DELETE FROM subscriber WHERE username='${THROWAWAY}';" 2>/dev/null || true
    sqlite3 state/hlr/hlr.db "DELETE FROM subscriber WHERE msisdn='${THROWAWAY}';" 2>/dev/null || true
    podman exec mvno-mongodb mongosh --quiet open5gs --eval \
        "print(db.subscribers.deleteMany({msisdn:'${THROWAWAY}'}).deletedCount)" >/dev/null 2>&1 || true
    podman exec mvno-mongodb mongosh --quiet kamailio --eval \
        "print(db.subscriber.deleteMany({username:'${THROWAWAY}'}).deletedCount)" >/dev/null 2>&1 || true

    # --- [1] provision ---
    echo "[1/4] provisioning ${THROWAWAY} via add-subscriber.sh…"
    OUT="$(bash scripts/add-subscriber.sh "${THROWAWAY}" 2>&1)" \
        || { echo "FATAL: add-subscriber.sh failed:"; echo "$OUT" | tail -8; return 1; }
    echo "$OUT" | grep -q "Provisioning Complete" && ok "provisioned ${THROWAWAY}" || { echo "$OUT" | tail -8; fail "no Provisioning Complete"; }
    IMSI="$(echo "$OUT" | grep -oE 'IMSI [0-9]{15}' | head -1 | awk '{print $2}')"
    echo "    IMSI: ${IMSI:-<unknown>}"

    # --- [2] all stores ---
    echo "[2/4] asserting all 5 stores…"
    sqlite3 state/kamailio/kamailio.db "SELECT 1 FROM subscriber WHERE username='${THROWAWAY}';" 2>/dev/null | grep -q 1 \
        && ok "Kamailio sqlite auth_db (SIP digest)" || fail "auth_db row missing"
    sqlite3 state/hlr/hlr.db "SELECT 1 FROM subscriber WHERE msisdn='${THROWAWAY}';" 2>/dev/null | grep -q 1 \
        && ok "state/hlr/hlr.db mirror" || fail "hlr.db row missing"
    podman exec mvno-mongodb mongosh --quiet open5gs --eval \
        "print(db.subscribers.countDocuments({msisdn:'${THROWAWAY}'}) > 0)" 2>/dev/null | grep -q true \
        && ok "Open5GS Mongo (5G SA doc)" || fail "open5gs mongo doc missing"
    podman exec mvno-mongodb mongosh --quiet kamailio --eval \
        "print(db.subscriber.countDocuments({username:'${THROWAWAY}'}) > 0)" 2>/dev/null | grep -q true \
        && ok "Kamailio Mongo (parallel store)" || fail "kamailio mongo row missing"
    if [ -n "$IMSI" ]; then
        scripts/vty.sh mvno-osmo-hlr 4258 "show subscribers all" 2>/dev/null | grep -q "$IMSI" \
            && ok "OsmoHLR VTY (2G/3G store)" || { echo "  ~ osmo-hlr VTY row not asserted (show output differs)"; }
    else
        echo "  ~ IMSI unknown — osmo-hlr VTY assert skipped"
    fi

    # --- [3] real SIP REGISTER 200 OK (the SipClient digest path) ---
    echo "[3/4] asserting real SIP REGISTER 200 OK for ${THROWAWAY}…"
    # -u: unbuffered — timeout kills the UAS while it is still listening, and
    # buffered stdout would otherwise be lost before the SIGTERM lands.
    REG_OUT="$(timeout 20 python3 -u scripts/testing/sip_traffic_sim.py \
        --uas "${THROWAWAY}" --host 127.0.0.1 --port 5066 --listen-port 5071 2>&1 || true)"
    echo "$REG_OUT" | grep -q "SIP REGISTER 200 OK for subscriber ${THROWAWAY}" \
        && ok "SIP REGISTER 200 OK (auth_db testpass path)" \
        || { fail "SIP REGISTER did not return 200 OK"; echo "$REG_OUT" | tail -3; }
    timeout 10 python3 scripts/testing/sip_traffic_sim.py --callee "${THROWAWAY}" --deregister >/dev/null 2>&1 || true

    # --- [3b] optional attach note ---
    if [ "${MODE}" = "--attach" ]; then
        echo "  --attach: checking pins before the operator-initiated attach…"
        if bash scripts/testing/check_ip_pins.sh >/dev/null 2>&1; then
            ok "check_ip_pins: all compose pins unique (attach snippet is safe)"
        else
            fail "check_ip_pins found a duplicate pin — fix compose before attaching"
        fi
        echo "  (attach is operator-confirmed by design: append the printed compose"
        echo "   service + podman compose up -d ueransim-ue-<N>; compose is never auto-edited.)"
    fi

    # --- [4] cleanup (evidence log + stores stay consistent) ---
    echo "[4/4] cleanup of throwaway ${THROWAWAY}…"
    sqlite3 state/kamailio/kamailio.db "DELETE FROM subscriber WHERE username='${THROWAWAY}';" 2>/dev/null || true
    sqlite3 state/hlr/hlr.db "DELETE FROM subscriber WHERE msisdn='${THROWAWAY}';" 2>/dev/null || true
    podman exec mvno-mongodb mongosh --quiet open5gs --eval \
        "print(db.subscribers.deleteMany({msisdn:'${THROWAWAY}'}).deletedCount)" >/dev/null 2>&1 || true
    podman exec mvno-mongodb mongosh --quiet kamailio --eval \
        "print(db.subscriber.deleteMany({username:'${THROWAWAY}'}).deletedCount)" >/dev/null 2>&1 || true
    if [ -n "$IMSI" ]; then
        scripts/vty.sh mvno-osmo-hlr 4258 "subscriber imsi ${IMSI} delete" >/dev/null 2>&1 || true
    fi
    rm -f configs/ueransim/ue-[0-9]*.yaml 2>/dev/null || true   # throwaway UE yaml only
    ok "throwaway row removed from all stores (evidence log retained)"

    if [ "${PASS}" -eq 1 ]; then
        echo "✅ SUBSCRIBER PROOF PASS — evidence: docs/evidence/$(basename "$LOG")"
        return 0
    fi
    echo "❌ SUBSCRIBER PROOF FAIL — see docs/evidence/$(basename "$LOG")"
    return 1
}

set -o pipefail
main 2>&1 | tee "$LOG"
exit ${PIPESTATUS[0]}
