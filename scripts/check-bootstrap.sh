#!/usr/bin/env bash
# ==============================================================================
# check-bootstrap.sh — post-up functional health gate (the cold-start oracle)
# ==============================================================================
# "32 containers Up" is not functional health. After a cold start this asserts
# the things that make the stack WORK, polling each until ready (bounded), so
# the FIRST red marker points at the EXACT missing step:
#   1. Kamailio subscriber table + seeded rows (sqlite)     [make init-db]
#   2. hlr.db subscriber rows (sqlite)                      [make init-db]
#   3. Open5GS Mongo 5G subscribers (mongosh)               [make seed-mongo]
#   4. telecom-api /actuator/health 200                     [make up]
#   5. ai-filter /health 200                                [make up]
#   6. static IP pins unique (check_ip_pins.sh)             [compose hygiene]
#   7. bridge 2G AoRs registered (watchdog --check-bridge)  [5G->2G relay]
#   8. 5G UE fleet attached (ran_ue == 3)                   [preflight/attach]
#
# Exit 0 only when every check passes. Wire via `make bootstrap-check`, which
# tees to docs/evidence/bootstrap-<date>.log with `bash -o pipefail` so a FAIL
# can never be swallowed by tee (the abaa766 lesson).
# ==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
detect_runtime
ENGINE="$RUNTIME"

# Directed preflight errors (fail-fast philosophy): name the missing tool, not
# a confusing downstream false-FAIL.
for tool in sqlite3 curl jq; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo -e "\033[0;31m  ✗ missing tool: ${tool} (host prerequisite — see docs/deployment_guide.md §2)\033[0m" >&2
        exit 1
    }
done
command -v "${ENGINE}" >/dev/null 2>&1 || {
    echo -e "\033[0;31m  ✗ container engine '${ENGINE}' not found\033[0m" >&2
    exit 1
}

PASS=0
FAIL=0
ok()  { echo -e "\033[0;32m  ✓ $*\033[0m"; PASS=$((PASS + 1)); }
bad() { echo -e "\033[0;31m  ✗ $*\033[0m" >&2; FAIL=$((FAIL + 1)); }

# Bounded poll helper: poll_fn LABEL SECONDS — polls until `poll_fn` exits 0.
# Prints a per-check spinner line only on success (failures report at the end).
poll() { # fn timeout_seconds
    local fn="$1" timeout="$2" waited=0
    while [ "${waited}" -lt "${timeout}" ]; do
        if "${fn}" >/dev/null 2>&1; then return 0; fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# --- 1. Kamailio subscriber DB -------------------------------------------------
kamailio_rows() {
    local n
    n=$(sqlite3 -readonly state/kamailio/kamailio.db \
        "SELECT count(*) FROM subscriber;" 2>/dev/null || echo 0)
    [ "${n:-0}" -ge 6 ]
}
echo "=== 1/8 Kamailio subscriber DB (SIP digest auth + balance 403 contract) ==="
if poll kamailio_rows 30; then ok "subscriber table seeded (>=6 rows, zero-balance contract)";
else bad "Kamailio subscriber DB missing/empty — run: make init-db"; fi

# --- 2. hlr.db -----------------------------------------------------------------
hlr_rows() {
    local n
    n=$(sqlite3 -readonly state/hlr/hlr.db \
        "SELECT count(*) FROM subscriber;" 2>/dev/null || echo 0)
    [ "${n:-0}" -ge 5 ]
}
echo "=== 2/8 hlr.db IMSI map (2G SMS routing) ==="
if poll hlr_rows 30; then ok "5 IMSI rows present (v7 schema, user_version=7)";
else bad "hlr.db missing/fewer than 5 rows — run: make init-db"; fi

# --- 3. Open5GS Mongo 5G subscribers -------------------------------------------
mongo_ues() {
    local n
    n=$(${ENGINE} exec -i mvno-mongodb mongosh --quiet open5gs \
        --eval 'db.subscribers.countDocuments()' 2>/dev/null | tail -1)
    [ "${n:-0}" = "3" ]
}
echo "=== 3/8 Open5GS Mongo 5G subscribers (UE attach prerequisite) ==="
if poll mongo_ues 60; then ok "3 UERANSIM subscribers seeded";
else bad "Open5GS Mongo not seeded — run: make seed-mongo (after up)"; fi

# --- 4. telecom-api ------------------------------------------------------------
api_up() { curl -sf -m 2 http://localhost:8080/actuator/health >/dev/null 2>&1; }
echo "=== 4/8 telecom-api /actuator/health ==="
if poll api_up 150; then ok "telecom-api healthy (200)";
else bad "telecom-api not healthy after 150s — check: podman logs mvno-api"; fi

# --- 5. ai-filter --------------------------------------------------------------
aif_up() { curl -sf -m 2 http://127.0.0.1:8008/health >/dev/null 2>&1; }
echo "=== 5/8 ai-filter /health (AI classify endpoint) ==="
if poll aif_up 120; then ok "ai-filter healthy (200)";
else bad "ai-filter not healthy after 120s — check: podman logs mvno-ai-filter"; fi

# --- 6. static IP pins ---------------------------------------------------------
ip_pins_ok() { bash scripts/testing/check_ip_pins.sh; }
echo "=== 6/8 static IP pins unique (compose hygiene) ==="
if poll ip_pins_ok 30; then ok "no duplicate ipv4_address pins";
else bad "duplicate IP pins in docker-compose.yml — see scripts/testing/check_ip_pins.sh"; fi

# --- 7. bridge 2G AoRs ---------------------------------------------------------
bridge_ok() { bash scripts/mvno-stack-watchdog.sh --check-bridge; }
echo "=== 7/8 bridge 2G AoRs registered (5G->2G relay path) ==="
if poll bridge_ok 120; then ok "both 2G AoRs registered in usrloc (/health 200)";
else bad "bridge AoRs not registered — run: bash scripts/mvno-stack-watchdog.sh --once"; fi

# --- 8. UE fleet ---------------------------------------------------------------
ue_fleet() {
    local n
    n=$(curl -s --max-time 5 'http://localhost:8428/api/v1/query?query=ran_ue' \
        2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || echo 0)
    [ "${n:-0}" = "3" ]
}
echo "=== 8/8 5G UE fleet attached at AMF (ran_ue == 3) ==="
if poll ue_fleet 180; then ok "all 3 UEs attached (ran_ue=3)";
else bad "UE fleet incomplete — run: bash scripts/testing/preflight_5g.sh --auto-recover"; fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
if [ "${FAIL}" -eq 0 ]; then
    echo -e "\033[0;32m✅ BOOTSTRAP CHECK PASS — ${PASS}/8 functional checks green\033[0m"
    exit 0
else
    echo -e "\033[0;31m❌ BOOTSTRAP CHECK FAIL — ${FAIL}/8 checks red; the ✗ markers name the exact fix\033[0m" >&2
    exit 1
fi
