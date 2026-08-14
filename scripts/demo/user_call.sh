#!/usr/bin/env bash
# ==============================================================================
# user_call.sh — USER-DRIVEN live VoIP call demo (dynamic caller + your voice)
# ------------------------------------------------------------------------------
# Lets the OPERATOR initiate a live call from their microphone. Unlike the
# automatic `demo_call.sh` tone-caller fallback, this always drives the baresip
# caller leg from the live mic (PulseAudio), so Vosk transcribes YOUR actual
# voice in near-real-time — the crucial "we see what you say" demo.
#
#   bash scripts/demo/user_call.sh [CALLEE]
#
#   [CALLEE] default 15559998888 (the 5G UAS rig). The caller MSISDN is fixed to
#   the tx rig's 15553332211. The operator SPEAKS for a 10s window.
#
# Reuses scripts/testing/demo_call.sh (the baresip dial rig) + mic_record.sh
# (16k capture) / live-tap (RTP->Vosk). Separation of concerns: no new call
# setup logic here, only the USER-driven input + ordering.
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CALLEE="${1:-15559998888}"

echo ""
echo "=============================================="
echo "  USER CALL — live mic voice -> 5G network"
echo "  caller 15553332211 (baresip-tx) -> ${CALLEE}"
echo "  SPEAK for 10s when prompted. Vosk transcribes YOUR words live."
echo "=============================================="
echo ""

# Smoke: is the baresip rig up? If not, use demo_call setup first.
if ! podman ps --format '{{.Names}}' | grep -q '^baresip-tx$'; then
    echo "(baresip rig not up — starting it via demo_call.sh setup)"
    bash "${REPO_ROOT}/scripts/testing/demo_call.sh" setup >/dev/null 2>&1 || true
fi

# Initiate the live call through the baresip rig.
bash "${REPO_ROOT}/scripts/testing/demo_call.sh" dial

# The call's RTP is tapped by live_tap -> Vosk spool -> NativeVoskService.
# Surface any live transcript that landed (the operator sees their words).
sleep 2
latest_txt="$(ls -t state/spool/archived/live-*.txt 2>/dev/null | head -1)"
if [ -n "$latest_txt" ] && grep -q '"text"' "$latest_txt"; then
    echo "🎙️  LIVE transcription (this call): $(grep -o '"text"[^,]*' "$latest_txt" | tr -d '"text: ')"
fi
echo "✅ USER CALL placed — check baresip-rx logs / pcap for the media path."