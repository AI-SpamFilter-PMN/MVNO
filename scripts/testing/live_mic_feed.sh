#!/usr/bin/env bash
# ==============================================================================
# live_mic_feed.sh — stream the REAL laptop mic into a growing WAV for baresip
# ==============================================================================
# Feeds the real host hardware mic (PipeWire/Pulse source
# alsa_input.pci-0000_05_00.6.analog-stereo — the laptop's default) as live
# audio into baresip-tx's aufile source.
#
# WHY (RCA 8.47): baresip's pulse.so NEVER records in this rootless-podman rig
# (always falls back to ausine 440Hz tone at call time), the host pulse socket
# doesn't deliver audio cross-namespace, and aufile rejects FIFOs (EBADMSG).
# aufile DOES accept a regular file — so we write a WAV header with an
# UNKNOWN data size (0xFFFFFFFF) and append raw s16le PCM live. If aufile
# streams (reads sequentially, not size-bounded), baresip-tx carries the live
# mic during the call.
#
# Usage:
#   bash scripts/testing/live_mic_feed.sh          # run until Ctrl-C
#   bash scripts/testing/live_mic_feed.sh --probe  # 3s mic self-test, exit
# Env:  MIC_SOURCE (default alsa_input.pci-0000_05_00.6.analog-stereo)
#       MIC_RATE (default 8000), MIC_FILE (default state/baresip/live/live.wav)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

MIC_SOURCE="${MIC_SOURCE:-alsa_input.pci-0000_05_00.6.analog-stereo}"
MIC_RATE="${MIC_RATE:-8000}"
MIC_FILE="${MIC_FILE:-state/baresip/live/live.wav}"

if [ "${1:-}" = "--probe" ]; then
    echo "── live_mic_feed --probe (3s) ──"
    timeout 5 parec --device="${MIC_SOURCE}" --format=s16le --rate="${MIC_RATE}" \
        --channels=1 --file-format=wav /tmp/mic-probe.wav 2>/dev/null || true
    ffmpeg -i /tmp/mic-probe.wav -af volumedetect -f null - 2>&1 \
        | rg 'mean_volume|max_volume' && rm -f /tmp/mic-probe.wav
    exit 0
fi

mkdir -p "$(dirname "${MIC_FILE}")"
echo "── live_mic_feed: ${MIC_SOURCE} @ ${MIC_RATE} Hz -> ${MIC_FILE} (Ctrl-C stops) ──"

# --- 1. Pre-write a valid WAV header with UNKNOWN sizes (data chunk 0xFFFFFFFF)
# so aufile can stream an ever-growing file; sizes are patched on exit.
python3 - "${MIC_FILE}" "${MIC_RATE}" <<'PYEOF'
import struct, sys
path, rate = sys.argv[1], int(sys.argv[2])
hdr = b'RIFF' + struct.pack('<I', 0xFFFFFFFF) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate*2, 2, 16)
hdr += b'data' + struct.pack('<I', 0xFFFFFFFF)
with open(path, 'wb') as f:
    f.write(hdr)
print(f"  ✓ WAV header written ({len(hdr)} B, {rate} Hz mono s16)")
PYEOF

# --- 2. Append live raw PCM from the real mic -------------------------------
parec --device="${MIC_SOURCE}" --format=s16le --rate="${MIC_RATE}" \
    --channels=1 --raw >> "${MIC_FILE}" &
PAREC_PID=$!
echo "  ✓ parec streaming (pid ${PAREC_PID})"

trap 'kill ${PAREC_PID} 2>/dev/null || true; echo "  ⏹ stopped"; exit 0' INT TERM
wait "${PAREC_PID}"
