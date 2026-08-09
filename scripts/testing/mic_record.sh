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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
source "${REPO_ROOT}/scripts/lib/common.sh"   # play_go_beep (go-cue) + side_tone_on/off (mic-monitor)
# Ctrl-C hygiene: never leave the side-tone loopback running if interrupted
# (idempotent — no-op on normal exit).
trap side_tone_off EXIT

DURATION="${1:-10}"
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
# Audible go-cue: the two-tone pep sound marks the exact moment recording
# starts — speak after you hear it (MVNO_NO_BEEP=1 to mute; never fatal).
play_go_beep
# Live side-tone: hear your own mic on the speakers while recording (host-only
# monitor; the captured WAV is the pure mic, so evidence stays honest).
# MVNO_NO_SIDETONE=1 disables; never active in headless proof runs.
side_tone_on
sleep 1    # reaction beat: first words land INSIDE the capture window

# Record live microphone audio using ffmpeg / pulse / arecord.
# ATOMIC-LANDING (Vosk watcher race): NativeVoskService polls the spool every
# 3s and processes any *.wav whose mtime age > 3s — a short capture is decoded
# MID-WRITE (transiently invalid header -> "File of unsupported format" ->
# EMPTY transcript, the exact mic_verify failure of 2026-08-09). The watcher's
# filter is endsWith(".wav"), so record to a ".part" name (invisible to it),
# then rename atomically — the watcher can only ever see a complete file.
REC_PART="${TARGET_PATH}.part"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -loglevel quiet -f pulse -i default -ar 16000 -ac 1 -t "${DURATION}" -f wav "${REC_PART}" 2>/dev/null || \
  ffmpeg -y -loglevel quiet -f alsa -i default -ar 16000 -ac 1 -t "${DURATION}" -f wav "${REC_PART}" 2>/dev/null || \
  arecord -f S16_LE -r 16000 -c 1 -d "${DURATION}" "${REC_PART}" 2>/dev/null
else
  arecord -f S16_LE -r 16000 -c 1 -d "${DURATION}" "${REC_PART}" 2>/dev/null
fi
mv -f "${REC_PART}" "${TARGET_PATH}"

# The Vosk watcher may archive (move) the WAV during our own sleep — tolerate
# the race: chmod only if the file is still in the spool root.
if [ -f "${TARGET_PATH}" ]; then
  chmod 777 "${TARGET_PATH}"
fi
echo "✓ Microphone recording captured successfully: ${TARGET_PATH}"
side_tone_off
echo ""
# ASR wait scales with capture length — a longer WAV takes Vosk longer to
# decode + archive (watcher polls every 3s). Allow ~2×duration + margin so
# the 16 kHz clip is fully transcribed before we give up.
ASR_WAIT="$(( DURATION * 2 + 6 ))"
echo "⏳ Waiting up to ${ASR_WAIT} s for Native Vosk ASR to transcribe this capture..."
elapsed=0
while [ "${elapsed}" -lt "${ASR_WAIT}" ]; do
  if [ -f "${TXT_PATH}" ]; then
    echo "------------------------------------------------------------------------"
    echo "🎉 Vosk ASR Live Transcription Result (${TXT_PATH}):"
    echo ""
    cat "${TXT_PATH}"
    echo ""
    exit 0
  fi
  printf "\r  live so far (%ss/%ss): listening…" "${elapsed}" "${ASR_WAIT}"
  sleep 1
  elapsed="$(( elapsed + 1 ))"
done
echo ""
echo "------------------------------------------------------------------------"
if [ -f "${TXT_PATH}" ]; then
  echo "🎉 Vosk ASR Live Transcription Result (${TXT_PATH}):"
  echo ""
  cat "${TXT_PATH}"
else
  echo "[-] File ${TXT_PATH} is still processing in background."
  echo "    Check status with: cat ${TXT_PATH}"
fi
echo "========================================================================"
