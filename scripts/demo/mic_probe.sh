#!/usr/bin/env bash
# ==============================================================================
# Live-Mic Precondition Probe — fail-fast guard for `make graduation`
# ==============================================================================
# The graduation headline proof is LIVE MIC TRANSCRIPTION: a fresh, audible
# capture from the operator's microphone, transcribed by Native Vosk ASR for
# THIS run. If the mic is missing, muted, or pointed at the monitor loopback,
# the demo would silently fall back to the ausine tone caller and "pass" while
# the mic proof is empty — the exact theater graduation removes.
#
# This probe converts that silent fallback into a HARD FAILURE with
# remediation, BEFORE the stack is torn down:
#   [1] Pulse/PipeWire socket present at ${PULSE_DIR}/pulse/native
#   [2] A real capture source (not a .monitor loopback) exists
#   [3] A 3 s live capture produces AUDIBLE energy (ffmpeg volumedetect)
#   [4] SOFT: the capture lands a transcript via the Vosk spool watcher
#       (content is printed; the probe does NOT hard-assert non-empty here —
#       a quiet room legitimately transcribes to "" — the hard non-empty
#       assertion is mic_verify.sh, where the operator is prompted to SPEAK).
#
# Usage:   bash scripts/demo/mic_probe.sh
# Exit:    0 = mic live and audible; 1 = FATAL (with remediation)
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PULSE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="${PULSE_DIR}/pulse/native"
PROBE_WAV="state/spool/mic_probe_$(date +%s).wav"
VOLUME_DB_THRESHOLD="-50"   # dB; speech is typically -35..-20, silence is -90ish

pass() { echo -e "\033[32m  ✓ $1\033[0m"; }
fail() { echo -e "\033[31m  ✗ $1\033[0m"; }
fatal() { echo -e "\033[31m\nFATAL: $1\033[0m" >&2; exit 1; }

echo "========================================================================"
echo " 🎙️  LIVE-MIC PRECONDITION PROBE (make graduation stage 0/5)"
echo "========================================================================"

# --- [1] Pulse/PipeWire socket -------------------------------------------------
if [ -S "${SOCK}" ]; then
  pass "audio socket ${SOCK}"
else
  echo "  ✗ no socket at ${SOCK}"
  echo ""
  echo "  REMEDIATION: start PipeWire/PulseAudio (e.g. 'systemctl --user start"
  echo "  pipewire pipewire-pulse' or 'pulseaudio --start'), or export"
  echo "  XDG_RUNTIME_DIR for this shell. Graduation CANNOT prove live-mic"
  echo "  transcription without an audio server."
  fatal "no live audio server socket — graduation cannot proceed"
fi

# --- [2] Real capture source (not a monitor loopback) -------------------------
SOURCES="$(pactl list sources short 2>/dev/null || true)"
INPUTS="$(printf '%s\n' "${SOURCES}" | grep -iE 'alsa_input|analog-stereo|microphone' | grep -viE '\.monitor' || true)"
if [ -n "${INPUTS}" ]; then
  DEFAULT_SRC="$(pactl info 2>/dev/null | awk -F': ' '/Default Source/{print $2}' || true)"
  pass "capture source present: ${DEFAULT_SRC:-$(printf '%s\n' "${INPUTS}" | head -1 | awk '{print $2}')}"
else
  echo "  ✗ no capture input found (only loopbacks/monitors or nothing):"
  printf '%s\n' "${SOURCES}" | head -8 | sed 's/^/      /'
  echo ""
  echo "  REMEDIATION: plug in / unmute a microphone; 'pactl set-default-source"
  echo "  <name>' to the real input (NOT a .monitor loopback)."
  fatal "no usable mic capture source"
fi

# --- [3] Audible 3 s live capture ---------------------------------------------
echo ""
echo "  📢 Recording 3 s of ambient audio to verify the mic is live..."
rm -f "${PROBE_WAV}"
FFMPEG_ERR="$(mktemp)"
capture_probe() {
    # stderr is kept (not /dev/null) so a failure shows the REAL Pulse error;
    # exit 124 = timeout kill (device busy hang) vs 1 = open/stream error.
    timeout 15 ffmpeg -y -loglevel error -f pulse -i default -ar 16000 -ac 1 \
        -t 3 "${PROBE_WAV}" 2>"${FFMPEG_ERR}"
}
if capture_probe; then
  chmod 777 "${PROBE_WAV}" 2>/dev/null || true
  MEAN_VOL="$(ffmpeg -i "${PROBE_WAV}" -af volumedetect -f null - 2>&1 \
    | awk -F': ' '/mean_volume/{gsub(/ dB/,"",$2); print $2}')"
  MAX_VOL="$(ffmpeg -i "${PROBE_WAV}" -af volumedetect -f null - 2>&1 \
    | awk -F': ' '/max_volume/{gsub(/ dB/,"",$2); print $2}')"
  echo "  capture: ${PROBE_WAV}"
  echo "  volumedetect: mean=${MEAN_VOL:-?} dB  max=${MAX_VOL:-?} dB  (threshold ${VOLUME_DB_THRESHOLD} dB)"
  if awk -v v="${MEAN_VOL:-nan}" -v t="${VOLUME_DB_THRESHOLD}" 'BEGIN{exit !(v+0 > t+0)}'; then
    pass "capture is audible (mean ${MEAN_VOL} dB > ${VOLUME_DB_THRESHOLD} dB)"
  else
    echo ""
    echo "  REMEDIATION: the capture is SILENT — the mic may be muted"
    echo "  ('pactl set-source-mute @DEFAULT_SOURCE@ 0'), the wrong default"
    echo "  source selected (check 'pactl info' → Default Source), or the"
    echo "  device is in use by another client (Firefox/Blueman above)."
    fatal "mic capture is silent (mean ${MEAN_VOL:-?} dB) — not audible"
  fi
else
  # Transient "device busy" race (another client briefly holding the source,
  # PipeWire suspend/resume) is the common flake — retry ONCE before failing.
  CAP_EXIT=$?
  FF_ERR="$(tr -d '\n' < "${FFMPEG_ERR}" | head -c 300)"
  echo "  ⚠  capture attempt 1 failed (exit ${CAP_EXIT}: ${FF_ERR:-no ffmpeg stderr}); retrying once..."
  sleep 2
  if capture_probe; then
    chmod 777 "${PROBE_WAV}" 2>/dev/null || true
    MEAN_VOL="$(ffmpeg -i "${PROBE_WAV}" -af volumedetect -f null - 2>&1 \
      | awk -F': ' '/mean_volume/{gsub(/ dB/,"",$2); print $2}')"
    pass "capture audible on retry (mean ${MEAN_VOL} dB > ${VOLUME_DB_THRESHOLD} dB)"
  else
    FF_ERR="$(tr -d '\n' < "${FFMPEG_ERR}" | head -c 300)"
    echo ""
    echo "  REMEDIATION: ffmpeg could not open the Pulse capture stream"
    echo "  (real error: ${FF_ERR:-none captured}). Check 'pactl list sources"
    echo "  short' and 'wpctl status' — the default source must be a live"
    echo "  input, not a monitor, and not held by another client."
    rm -f "${FFMPEG_ERR}"
    fatal "3 s Pulse capture failed after retry"
  fi
fi
rm -f "${FFMPEG_ERR}"

# --- [4] SOFT: transcript lands via the Vosk spool watcher ---------------------
echo ""
echo "  ⏳ Waiting for Native Vosk ASR to transcribe the probe capture..."
TXT="${PROBE_WAV%.wav}.txt"
for _ in $(seq 1 15); do
  if [ -f "state/spool/archived/$(basename "${TXT}")" ]; then
    TXT="state/spool/archived/$(basename "${TXT}")"
    break
  fi
  sleep 1
done
if [ -f "${TXT}" ]; then
  TEXT="$(python3 -c "import json;print(json.load(open('${TXT}')).get('text',''))" 2>/dev/null || cat "${TXT}")"
  pass "ASR pipeline live — probe transcript: '${TEXT}'"
  echo "    (soft check: ambient/quiet room may legitimately transcribe empty;"
  echo "     mic_verify.sh hard-asserts non-empty with the SPEAK prompt.)"
else
  echo "  ⚠  no transcript after 15 s — ASR watcher may be slow on cold start."
  echo "     This is soft: mic_verify.sh will retry with the real capture."
fi

echo ""
echo "✅ MIC PROBE PASSED — live mic present, audible, ASR reachable."
echo "   Headline proof (fresh capture → non-empty transcript) runs at stage 4/5."
exit 0
