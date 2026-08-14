#!/usr/bin/env bash
# ==============================================================================
# user_demo.sh — USER-DRIVEN live MVNO demo orchestrator
# ------------------------------------------------------------------------------
# The "we drive it live" companion to `make graduation` (which is the AUTO,
# deterministic gate). THIS menu runs the USER-interactive scripts with LIVE,
# dynamic inputs from the operator — custom SMS bodies, your own voice on a
# call, live re-runs — and prints the correct ORDER.
#
#   bash scripts/demo/user_demo.sh            # interactive menu
#   bash scripts/demo/user_demo.sh sms        # jump straight to User SMS
#   bash scripts/demo/user_demo.sh call       # jump straight to User Call
#
# Auto vs User split (YAGNI: each User-* reuses the existing tested primitive):
#   auto:   make graduation / gate / sms_matrix.sh / demo_call.sh (canned)
#   user:   user_sms.sh (your SMS body) / user_call.sh (your voice live)
#
# Order (readiness first, then live):
#   1) stack up             make up
#   2) mic probe            mic_probe.sh       (live mic audible?)
#   3) User SMS             user_sms.sh        (type any body, any flow)
#   4) User Call            user_call.sh       (speak 10s, see your words)
#   5) evidence             view docs/evidence / prometheus scamflag
# ==============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

menu() {
    clear 2>/dev/null || true
    echo "═══════════════════════════════════════════════════════════"
    echo "  MVNO USER-DRIVEN LIVE DEMO — you drive, the network shows"
    echo "═══════════════════════════════════════════════════════════"
    echo "  1) Verify stack is up        (make up)"
    echo "  2) Microphone live probe     (mic_probe.sh)"
    echo "  3) USER SMS (any flow)       (user_sms.sh  <body> [flow])"
    echo "     flows: 2g2g 2g5g 5g2g 5g5g ai"
    echo "  4) USER LIVE VOICE CALL      (user_call.sh [callee])"
    echo "  5) Scam-flag evidence        (prometheus mvno.vosk.scamflag)"
    echo "  0) Exit"
    echo "───────────────────────────────────────────────────────────"
    printf 'Choose [0-5]: '
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        sms|3) echo "→ USER SMS"; bash "${REPO_ROOT}/scripts/demo/user_sms.sh" "${2:-}" "${3:-2g2g}" ;;
        call|4) echo "→ USER LIVE CALL"; bash "${REPO_ROOT}/scripts/demo/user_call.sh" "${2:-15559998888}" ;;
        probe|2) echo "→ mic probe"; bash "${REPO_ROOT}/scripts/demo/mic_probe.sh" ;;
        up|1) ( cd "${REPO_ROOT}" && make up ) ;;
        evidence|5)
            echo "→ scam-flag evidence:"; curl -s localhost:8080/actuator/prometheus | grep -E 'mvno_vosk_scamflag|mvno_vosk_flagged|mvno_vosk_blocked' || echo "(none yet)" ;;
        *) echo "usage: $0 [sms|call|probe|up|evidence]  |  plain menu" >&2; exit 1 ;;
    esac
    exit $?
fi

while true; do
    menu
    IFS= read -r choice || break
    case "${choice:-}" in
        1) ( cd "${REPO_ROOT}" && make up ) ;;
        2) bash "${REPO_ROOT}/scripts/demo/mic_probe.sh" ;;
        3) bash "${REPO_ROOT}/scripts/demo/user_sms.sh" ;;
        4) bash "${REPO_ROOT}/scripts/demo/user_call.sh" "15559998888" ;;
        5) curl -s localhost:8080/actuator/prometheus | grep -E 'mvno_vosk_scamflag|mvno_vosk_flagged' || echo "(none yet)" ;;
        0) echo "bye"; exit 0 ;;
        *) echo "invalid choice" ;;
    esac
    echo; echo "──────────────────────────────────────────"; echo "press Enter to return to menu"; read -r _
done