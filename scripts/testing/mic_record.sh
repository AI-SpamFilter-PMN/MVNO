#!/usr/bin/env bash
# ==============================================================================
# Live Laptop Microphone Speech-to-Text Recording Tool
# ==============================================================================
# Records live spoken audio directly from your Legion5 laptop microphone using
# ALSA / PulseAudio / PipeWire, saves it as 16kHz PCM WAV in state/spool/, and
# lets Native Vosk ASR transcribe what you spoke in real-time!
#
# Usage:
#   ./scripts/testing/mic_record.sh [duration_in_seconds]
# Example:
#   ./scripts/testing/mic_record.sh 5
# ==============================================================================

set -euo pipefail

DURATION="${1:-5}"
FILENAME="mic_call_$(date +%s).wav"
TARGET_PATH="state/spool/${FILENAME}"
TXT_PATH="state/spool/archived/${FILENAME%.wav}.txt"

echo "========================================================================"
echo " 🎙️ Live Laptop Microphone Speech-to-Text Recorder"
echo "========================================================================"
echo "  Duration:  ${DURATION} seconds"
echo "  Target:    ${TARGET_PATH}"
echo ""
echo "📢 Speak clearly into your laptop microphone now..."
echo "------------------------------------------------------------------------"

# Record live microphone audio using ffmpeg / pulse / arecord
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -loglevel quiet -f pulse -i default -ar 16000 -ac 1 -t "${DURATION}" "${TARGET_PATH}" 2>/dev/null || \
  ffmpeg -y -loglevel quiet -f alsa -i default -ar 16000 -ac 1 -t "${DURATION}" "${TARGET_PATH}" 2>/dev/null || \
  arecord -f S16_LE -r 16000 -c 1 -d "${DURATION}" "${TARGET_PATH}" 2>/dev/null
else
  arecord -f S16_LE -r 16000 -c 1 -d "${DURATION}" "${TARGET_PATH}" 2>/dev/null
fi

# The Vosk watcher may archive (move) the WAV during our own sleep — tolerate
# the race: chmod only if the file is still in the spool root.
if [ -f "${TARGET_PATH}" ]; then
  chmod 777 "${TARGET_PATH}"
fi
echo "✓ Microphone recording captured successfully: ${TARGET_PATH}"
echo ""
echo "⏳ Waiting 4 seconds for Native Vosk ASR engine to process audio..."
sleep 4

echo "------------------------------------------------------------------------"
if [ -f "${TXT_PATH}" ]; then
  echo "🎉 Vosk ASR Live Transcription Result (${TXT_PATH}):"
  echo ""
  cat "${TXT_PATH}"
  echo ""
else
  echo "[-] Waiting 2 more seconds for ASR background thread..."
  sleep 2
  if [ -f "${TXT_PATH}" ]; then
    echo "🎉 Vosk ASR Live Transcription Result (${TXT_PATH}):"
    echo ""
    cat "${TXT_PATH}"
    echo ""
  else
    echo "[-] File ${TXT_PATH} is still processing in background."
    echo "    Check status with: cat ${TXT_PATH}"
  fi
fi
echo "========================================================================"
