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
#   gate.sh  ->  (1) preflight_5g.sh  : 5G user plane UP (live uesimtun0 IP,
#                                        REGISTER 200 OK + GTP-U DL emitted)
#                (2) sms_matrix.sh   : SMS interworking 4-cell + AI-block
#                                        (2G->2G, 2G->5G, 5G->2G, 5G->5G, block)
#
# Exit 0 = all gates green; otherwise the failing gate's message is the fix.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "\033[0;36m==== MVNO DETERMINISTIC GATE ====${NC}"

# --- (1) 5G SA user-plane preflight (Issue 5.8/5.9 family) -------------------
echo -e "${CYAN:-}--- gate 1/2: 5G user-plane preflight (preflight_5g.sh) ---${NC:-}"
if bash scripts/testing/preflight_5g.sh; then
    echo -e "${GREEN}  gate 1/2 PASS: 5G user plane UP${NC}"
else
    echo -e "${RED}  gate 1/2 FAIL: 5G user plane down (see [preflight-5g] for the fix)${NC}"
    exit 1
fi

# --- (2) End-to-end SMS interworking + AI-block (sms_matrix.sh) -------------
echo -e "\033[0;36m--- gate 2/2: e2e SMS interworking (sms_matrix.sh) ---${NC}"
if bash scripts/testing/sms_matrix.sh; then
    echo -e "${GREEN}  gate 2/2 PASS: e2e 4-cell + AI-block green${NC}"
else
    echo -e "${RED}  gate 2/2 FAIL: sms_matrix failed (see evidence/e2e-run-*.log)${NC}"
    exit 1
fi

echo -e "${GREEN}==== GATE PASS — MVNO stack deterministic-verified ====${NC}"
