#!/usr/bin/env bash
# ==============================================================================
# flag_watch.sh — Flag-for-Review watcher (tails mvno-api verdicts)
# ==============================================================================
# Watches the mvno-api log stream for blocked TRANSCRIPT verdicts
# ("AI transcript verdict [<id>]: allow=false") and hands each one to
# flag_call.sh for evidence preservation + local-Neon flag rows.
#
# Usage:
#   bash scripts/review/flag_watch.sh          # follow forever (daemon)
#   bash scripts/review/flag_watch.sh --once   # replay recent blocks, exit 0
#   bash scripts/review/flag_watch.sh --window <minutes>   # replay window
#
# The verdict line format (NativeVoskService.classifyAndRecord):
#   AI transcript verdict [<recordingId>]: allow=false, reason='<reason>'
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

MODE="${1:-follow}"
SINCE_WINDOW="${2:-30}"

# --- extract <id> and <reason> from a verdict log line ------------------------
handle_line() {
    local line="$1" rec="" reason=""
    rec="$(printf '%s' "$line" | sed -n "s/.*AI transcript verdict \[\([^]]*\)\]: allow=false.*/\1/p")"
    [ -n "$rec" ] || return 0
    reason="$(printf '%s' "$line" | sed -n "s/.*reason='\([^']*\)'.*/\1/p")"
    # Skip if this recording was already flagged (manifest hit)
    if grep -q "\"recording_id\":\"${rec}\"" state/review/manifest.jsonl 2>/dev/null; then
        return 0
    fi
    echo "  ⚑ blocked verdict: ${rec} (${reason})"
    bash scripts/review/flag_call.sh "$rec" "${reason:-potential scam (voice transcript)}" || echo "  ⚠ flag_call.sh failed for ${rec}"
}

case "${MODE}" in
    --once)
        echo "── flag_watch --once (last ${SINCE_WINDOW}m) ──"
        podman logs mvno-api --since "${SINCE_WINDOW}m" 2>&1 \
            | grep "AI transcript verdict" \
            | while IFS= read -r l; do handle_line "$l"; done
        echo "✅ --once replay done"
        ;;
    --window)
        echo "── flag_watch --window ${SINCE_WINDOW}m ──"
        podman logs mvno-api --since "${SINCE_WINDOW}m" 2>&1 \
            | grep "AI transcript verdict" \
            | while IFS= read -r l; do handle_line "$l"; done
        ;;
    *)
        echo "── flag_watch follow (Ctrl-C to stop) ──"
        podman logs -f mvno-api 2>&1 \
            | while IFS= read -r l; do
                case "$l" in
                    *"AI transcript verdict"*) handle_line "$l" ;;
                esac
            done
        ;;
esac
