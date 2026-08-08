#!/usr/bin/env bash
# ==============================================================================
# silence_mark.sh — annotate a recorded proof artifact with a transcript or a
# silence symbol-block. Read-only: NEVER fabricates words — a quiet recording
# is labeled explicitly as silence, one symbol per recorded second.
#
#   bash scripts/testing/silence_mark.sh <wav> <txt> <label>
#
#   - <txt> non-empty  -> echoes "[label · recorded Ns · transcript]" + the
#                         transcript verbatim (real speech won)
#   - <txt> empty/missing -> "[label · recorded Ns · SILENCE "···" N symbols]"
#
# Used only by the proof harnesses (cockpit_proof --live-mic). The graduation
# anti-theater gate (mic_verify.sh) is untouched and still hard-fails on
# silence.
# ==============================================================================
set -euo pipefail

WAV="${1:?usage: silence_mark.sh <wav> <txt> <label>}"
TXT="${2:?usage: silence_mark.sh <wav> <txt> <label>}"
LABEL="${3:?usage: silence_mark.sh <wav> <txt> <label>}"

DUR=0
if command -v ffprobe >/dev/null 2>&1 && [ -f "$WAV" ]; then
    DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null | cut -d. -f1 || true)"
fi
DUR="${DUR:-0}"

if [ -s "$TXT" ]; then
    echo "[${LABEL} · recorded ${DUR}s · transcript]"
    cat "$TXT"
    exit 0
fi

# Silence: one '·' per recorded second (capped at 80 symbols to keep the log
# readable for very long captures; the raw WAV + empty .txt remain the honest
# primary evidence).
N=0
case "$DUR" in
    ''|*[!0-9]*) N=0 ;;
    *) N="$DUR" ;;
esac
[ "$N" -gt 80 ] && N=80
BLOCK=""
for ((i = 0; i < N; i++)); do BLOCK+="·"; done
echo "[${LABEL} · recorded ${DUR}s · SILENCE \"${BLOCK}\" ${DUR} symbols]"
echo "  (no speech detected — raw WAV + empty transcript kept as evidence;"
echo "   real-voice headline NOT proven this run)"
exit 0
