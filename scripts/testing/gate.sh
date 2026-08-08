#!/usr/bin/env bash
# ==============================================================================
# gate.sh — MVNO deterministic gate (exit-code only; no mic, no TTY)
# ==============================================================================
# The "source of truth" per AGENTS.md Karpathy rule 4: a repeatable, fully
# deterministic verification suite that never depends on interactive input.
# The live demo (live_demo.sh) is the labelled showcase ON TOP of this gate.
#
#   The assertion-count contract lives in docs/VERIFICATION_MODEL.md — if any
#   doc quotes a cell/item count that disagrees with it, the contract doc wins.
#
#   gate.sh  ->  (0) check-subscribers.sh  : subscriber-topology drift guard
#               (1) preflight_5g.sh        : 5G user plane UP (live uesimtun0
#                                            IP, REGISTER 200 OK + GTP-U DL
#                                            emitted)
#               (2) sms_matrix.sh          : SMS interworking 4-cell + AI-block
#                                            (2G->2G, 2G->5G, 5G->2G, 5G->5G,
#                                            block)
#
# Exit 0 = all gates green; otherwise the failing gate's message is the fix.
#
# Re-entrancy: the gate holds the shared mvno-gate.lock (registry in
# scripts/lib/common.sh) so the watchdog's run_in_flight guard sees the whole
# gate run — including the preflight window — and never recovers mid-gate.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"
source "${SCRIPT_DIR}/../lib/common.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# Refuse to run while ANOTHER orchestrator is active (live_demo/cockpit/proofs)
# — a concurrent demo would pollute the deterministic counter assertions. The
# sms-matrix lock is not yet held (we launch it ourselves below), so no
# exclusion is needed here.
if run_in_flight; then
    echo -e "${RED}  gate 0/3 FAIL: another run is in flight (registry lock or cockpit session 'mvno-live') — refusing to collide. Wait for it to finish, or: bash scripts/demo/demo_live.sh --down (cockpit) — stale dead-PID locks in ${TMPDIR:-/tmp}/mvno-*.lock are auto-recovered by the next acquirer${NC}" >&2
    exit 1
fi
acquire_run_lock mvno-gate.lock || { echo -e "${RED}  gate refused to start (lock held)${NC}" >&2; exit 1; }

echo -e "${CYAN}==== MVNO DETERMINISTIC GATE ====${NC}"

# --- (0) Subscriber-topology drift guard -------------------------------------
echo -e "${CYAN}--- gate 0/3: subscriber topology drift check (check-subscribers.sh) ---${NC}"
if bash scripts/check-subscribers.sh; then
    echo -e "${GREEN}  gate 0/3 PASS: subscriber constants consistent across scripts + seeds${NC}"
else
    echo -e "${RED}  gate 0/3 FAIL: subscriber drift detected (see check-subscribers output)${NC}"
    exit 1
fi

# --- (1) 5G SA user-plane preflight (Issue 5.8/5.9 family) -------------------
echo -e "${CYAN}--- gate 1/3: 5G user-plane preflight (preflight_5g.sh) ---${NC}"
if bash scripts/testing/preflight_5g.sh; then
    echo -e "${GREEN}  gate 1/3 PASS: 5G user plane UP${NC}"
else
    echo -e "${RED}  gate 1/3 FAIL: 5G user plane down (see [preflight-5g] for the fix)${NC}"
    exit 1
fi

# --- (2) End-to-end SMS interworking + AI-block (sms_matrix.sh) -------------
echo -e "${CYAN}--- gate 2/3: e2e SMS interworking (sms_matrix.sh) ---${NC}"
if bash scripts/testing/sms_matrix.sh; then
    echo -e "${GREEN}  gate 2/3 PASS: e2e 4-cell + AI-block green${NC}"
else
    echo -e "${RED}  gate 2/3 FAIL: sms_matrix failed (see evidence/e2e-run-*.log)${NC}"
    exit 1
fi

echo -e "${GREEN}==== GATE PASS — MVNO stack deterministic-verified ====${NC}"
