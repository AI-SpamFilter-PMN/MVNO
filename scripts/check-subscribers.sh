#!/usr/bin/env bash
# ==============================================================================
# check-subscribers.sh — subscriber-topology drift guard (deterministic)
# ==============================================================================
# The canonical MVNO test-subscriber set lives in ONE place:
#   scripts/lib/common.sh  (MVNO_MSISDN_* / MVNO_UAS_AOR / MVNO_THROWAWAY)
# Every script and seed must reference those constants or, at worst, a literal
# that matches them exactly. This guard fails the run if:
#
#   [1] any MSISDN literal in scripts/ + Makefile is NOT in the canonical set
#       (catches phantom/typo'd numbers — e.g. a 9-digit slip, a stale identity
#       left behind after a rename, or a hardcoded subscriber that was dropped)
#   [2] the Makefile init-db seeds drift from the contract:
#         - every canonical MSISDN must be seeded
#         - MVNO_MSISDN_ZERO must be seeded with balance 0 (SIP 403 contract)
#         - MVNO_MSISDN_FUNDED must be seeded with balance 100
#   [3] the bridge-owned 2G AoRs (MVNO_MSISDN_2G) differ from the watchdog's
#       --check-bridge list (they are the same source, so this is structural)
#
# Exit 0 = consistent; 1 = drift (list the offenders). Deterministic — wired
# into make gate as gate 0/3 and available standalone via `make check-subs`.
# ==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
source "${REPO_ROOT}/scripts/lib/common.sh"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Canonical set (from common.sh) + the sanctioned throwaway.
CANON="$(printf '%s\n' "${MVNO_MSISDN_ALL[@]}" "${MVNO_THROWAWAY}")"

echo "==== SUBSCRIBER TOPOLOGY DRIFT GUARD (single source: scripts/lib/common.sh) ===="
echo "  canonical MSISDNs: ${MVNO_MSISDN_ALL[*]}  (throwaway: ${MVNO_THROWAWAY})"

# --- [1] stray literals ------------------------------------------------------
STRAY="$(grep -rhoE '1555[0-9]{7}' scripts/ Makefile 2>/dev/null | sort -u \
         | grep -vxF "${CANON}" || true)"
if [ -z "$STRAY" ]; then
    ok "no stray MSISDN literals — every '1555*' in scripts/ + Makefile is canonical"
else
    fail "stray MSISDN literal(s) NOT in the canonical set:"
    echo "$STRAY" | sed 's/^/       /'
fi

# --- [2] Makefile init-db seeds + balance contract ---------------------------
for m in "${MVNO_MSISDN_ALL[@]}"; do
    grep -qE "'${m}'" Makefile && ok "Makefile init-db seeds ${m}" \
        || fail "Makefile init-db does not seed ${m}"
done
grep -qE "'${MVNO_MSISDN_ZERO}', 0[,)]" Makefile \
    && ok "zero-balance contract: ${MVNO_MSISDN_ZERO} seeded balance 0" \
    || fail "Makefile drift: ${MVNO_MSISDN_ZERO} not seeded with balance 0 (breaks live_demo [6/13] 403)"
grep -qE "'${MVNO_MSISDN_FUNDED}', 100[,)]" Makefile \
    && ok "funded contract: ${MVNO_MSISDN_FUNDED} seeded balance 100" \
    || fail "Makefile drift: ${MVNO_MSISDN_FUNDED} not seeded with balance 100"

# --- [3] bridge 2G AoRs vs watchdog ------------------------------------------
WDOG_AORS="$(grep -oE 'MVNO_MSISDN_2G\[@\]' scripts/mvno-stack-watchdog.sh | head -1)"
if [ -n "$WDOG_AORS" ]; then
    ok "watchdog derives bridge AoRs from MVNO_MSISDN_2G (single source)"
else
    fail "watchdog no longer derives bridge AoRs from MVNO_MSISDN_2G — re-check scripts/mvno-stack-watchdog.sh"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "✅ SUBSCRIBER TOPOLOGY CONSISTENT (${PASS} checks)"
    exit 0
fi
echo "❌ SUBSCRIBER DRIFT: ${FAIL} check(s) failed — fix before running the gate" >&2
exit 1
