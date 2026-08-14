#!/usr/bin/env bash
# demo_call.sh — baresip call rig for LIVE_DEMO S3 (one-liner wrapper)
#
#   bash scripts/testing/demo_call.sh setup   # speech file + baresip UAs (~15 s)
#   bash scripts/testing/demo_call.sh dial    # real call: callee streams the scam phrase; TALK NOW for ~10 s
#   bash scripts/testing/demo_call.sh hangup  # hang up (dial already hangs up; safety net)
#
# PORTABLE BY DESIGN: both UAs run from the packaged `mvno-baresip` image, so
# S3 needs NO host /usr/bin/baresip, no host-library mounts, and no host-model
# baresip build. The callee leg streams a real WAV through aufile (the load-
# bearing scam media). The caller leg uses the host PulseAudio socket when it
# is present (live mic) and otherwise falls back to a container-side aufile
# leg — either way the call is real and RTPEngine records it.
#
# Evidence stays INLINE in the guide: podman logs baresip-rx / pcap listing /
# RTPEngine counters. This script only assembles the rig (the mechanical part).

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "${REPO_ROOT}/scripts/lib/common.sh"   # play_go_beep (go-cue) + side_tone_on/off (mic-monitor)

CALLER=15553332211
CALLEE=15559998888
SIP_HOST=10.89.0.23
IMAGE="${BARESIP_IMAGE:-mvno-baresip:1.1.0}"
NET=("--network" "mvno_mvno_net")
# Realistic scam phrase, Vosk-small-model vetted (2026-08-08: transcribes as
# "your bank account has been blocked please confirm your detail now" — the
# keyword anchors account/blocked/confirm survive ASR, so the ai-filter
# TRANSCRIPT rule blocks deterministically). Override for a custom demo:
#   SCAM_PHRASE="Your card was charged, call us now" bash demo_call.sh setup
SCAM_PHRASE="${SCAM_PHRASE:-Your bank account has been blocked, please confirm your details now}"

# Portable host PulseAudio socket (XDG runtime dir; fall back to uid-based path).
# MVNO_FORCE_TONE=1 — deterministic/headless runs (cockpit-proof, CI) must
# never depend on the operator's mic: force the canned tone caller even when a
# live Pulse socket exists.
PULSE_OK=0
PULSE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -S "${PULSE_DIR}/pulse/native" ] && [ "${MVNO_FORCE_TONE:-0}" != "1" ]; then
  PULSE_OK=1
fi

module_path() {
  # baresip image installs modules under /usr/local/lib/baresip/modules
  echo "module_path /usr/local/lib/baresip/modules"
}

setup() {
  echo "=== demo_call.sh setup: speech file + baresip rig ==="
  espeak-ng -v en-us "$SCAM_PHRASE" -w /tmp/speech.wav
  mkdir -p state/baresip/rx state/baresip/tx
  ffmpeg -y -loglevel error -i /tmp/speech.wav -ar 8000 -ac 1 -c:a pcm_s16le \
    state/baresip/speech8k.wav
  echo "  callee phrase: ${SCAM_PHRASE}"

  cat > state/baresip/rx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module ausine.so
module aufile.so
module pulse.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
EOF
  if [ "$PULSE_OK" -eq 1 ]; then
    # Issue 8.47 proven recipe: full-duplex live audio both ends. The callee
    # leg (baresip-rx) captures the laptop HW mic (pulse source) and plays the
    # remote leg (phone mic) on the laptop speakers (pulse player) — so the
    # laptop mic is LIVE in BOTH call directions (phone->rig and rig->phone).
    cat >> state/baresip/rx/config <<EOF
audio_source pulse,alsa_input.pci-0000_05_00.6.analog-stereo
audio_player pulse,alsa_output.pci-0000_05_00.6.analog-stereo
EOF
  else
    # Headless/tone fallback: callee streams the canned scam phrase.
    cat >> state/baresip/rx/config <<EOF
audio_source aufile,/media/speech8k.wav
EOF
  fi
  cat > state/baresip/rx/accounts <<EOF
<sip:${CALLEE}@${SIP_HOST}:5060>;auth_user=${CALLEE};auth_pass=testpass;answermode=auto
EOF
  # Caller leg: use the live host mic when a Pulse socket exists, else a
  # container-side speech tone (portable fallback — still a real call).
  # Caller leg audio path (Issue 8.47, FIXED 2026-08-13): baresip's pulse.so
  # DOES capture the real laptop HW mic in this rootless rig when the container
  # runs as root (uid 0) with --security-opt label=disable, the host pulse
  # socket + cookie mounted, and PULSE_SERVER/XDG_RUNTIME_DIR set. The aufile
  # streaming workaround is no longer needed for live laptop-mic capture.
  local tx_src="ausine"
  if [ "$PULSE_OK" -eq 1 ]; then
    tx_src="pulse"
  fi
  cat > state/baresip/tx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module ausine.so
module aufile.so
module pulse.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
ctrl_tcp_listen 0.0.0.0:4444
EOF
  if [ "$PULSE_OK" -eq 1 ]; then
    # Live laptop mic + speakers via baresip's pulse module (Issue 8.47
    # proven recipe): real-time full-duplex capture, no file, no feeder.
    cat >> state/baresip/tx/config <<EOF
audio_source pulse,alsa_input.pci-0000_05_00.6.analog-stereo
audio_player pulse,alsa_output.pci-0000_05_00.6.analog-stereo
EOF
  else
    cat >> state/baresip/tx/config <<EOF
audio_source ausine
EOF
  fi
  cat > state/baresip/tx/accounts <<EOF
<sip:${CALLER}@${SIP_HOST}:5060>;auth_user=${CALLER};auth_pass=testpass
EOF

  podman rm -f baresip-rx baresip-tx 2>/dev/null
  if [ "$PULSE_OK" -eq 1 ]; then
    # Issue 8.47 proven recipe: root (uid 0), label=disable, host pulse socket
    # + cookie mounted, PULSE_SERVER/XDG_RUNTIME_DIR set. baresip's pulse.so
    # then captures the real laptop HW mic and plays to the laptop speakers.
    PULSE_SOCK="${PULSE_DIR}/pulse/native"
    PULSE_COOKIE="${HOME}/.config/pulse/cookie"
    podman run -d --name baresip-rx "${NET[@]}" --ip 10.89.0.60 \
      --security-opt label=disable \
      -e PULSE_SERVER="unix:${PULSE_SOCK}" -e XDG_RUNTIME_DIR="${PULSE_DIR}" \
      -v "${PULSE_SOCK}:${PULSE_SOCK}:ro" \
      -v "${PULSE_COOKIE}:${PULSE_DIR}/pulse/cookie:ro" \
      -v $PWD/state/baresip/rx:/cfg:z \
      -v $PWD/state/baresip/speech8k.wav:/media/speech8k.wav:ro \
      "${IMAGE}" >/dev/null
    podman run -d --name baresip-tx "${NET[@]}" --ip 10.89.0.61 \
      --security-opt label=disable \
      -e PULSE_SERVER="unix:${PULSE_SOCK}" -e XDG_RUNTIME_DIR="${PULSE_DIR}" \
      -v "${PULSE_SOCK}:${PULSE_SOCK}:ro" \
      -v "${PULSE_COOKIE}:${PULSE_DIR}/pulse/cookie:ro" \
      -v $PWD/state/baresip/tx:/cfg:z \
      "${IMAGE}" >/dev/null
  else
    podman run -d --name baresip-rx "${NET[@]}" --ip 10.89.0.60 \
      -v $PWD/state/baresip/rx:/cfg:z \
      -v $PWD/state/baresip/speech8k.wav:/media/speech8k.wav:ro \
      "${IMAGE}" >/dev/null
    podman run -d --name baresip-tx "${NET[@]}" --ip 10.89.0.61 \
      -v $PWD/state/baresip/tx:/cfg:z \
      "${IMAGE}" >/dev/null
  fi
  sleep 3
  echo "  rx registrations (expect >= 2): $(podman logs baresip-rx | grep -c '200 OK')"
  echo "  tx registrations (expect >= 2): $(podman logs baresip-tx 2>&1 | grep -c '200 OK')"
  echo "  caller audio source: ${tx_src} (PULSE_OK=${PULSE_OK})"
  echo "  ✓ rig ready — paste: bash scripts/testing/demo_call.sh dial"
}

ctrl_cmd() {
  local cmd="$1"
  podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; \
    printf '${#cmd}:${cmd},' >&3; timeout 2 cat <&3"
}

dial() {
  # Ctrl-C hygiene: if the operator interrupts the SPEAK NOW window, the
  # side-tone loopback must not linger (idempotent — no-op on normal exit).
  trap side_tone_off EXIT
  echo "=== demo_call.sh dial: ${CALLER} -> ${CALLEE} ==="
  ctrl_cmd "{\"command\":\"dial\",\"params\":\"sip:${CALLEE}@${SIP_HOST}:5060\"}"
  if [ "$PULSE_OK" -eq 1 ] && [ -t 0 ]; then
    echo "  ⏳ The caller leg is LIVE on your microphone. In ~3s SPEAK FREELY for ~10s"
    echo "     (whatever comes to mind — Vosk transcribes YOUR voice; the callee leg"
    echo "     streams the scam phrase so a block verdict is guaranteed either way):"
    echo "        optional phrase: \"${SCAM_PHRASE}\""
    sleep 3
    # Audible go-cue: the two-tone pep sound means "the call is live NOW —
    # start talking" (plays over the host speakers; MVNO_NO_BEEP=1 to mute).
    play_go_beep
    # Live side-tone: host-only mic -> speakers loopback so the operator hears
    # their own voice in real time while speaking (like a phone earpiece). The
    # recorded call path (baresip-tx -> RTP -> RTPEngine -> pcap/WAV) is
    # untouched, so evidence stays honest. MVNO_NO_SIDETONE=1 disables; never
    # active in the tone-caller/headless branch below.
    side_tone_on
    for s in 10 9 8 7 6 5 4 3 2 1; do
      printf "  >>> SPEAK NOW (%ss window) ...\r" "$s"
      sleep 1
    done
    echo ""
    side_tone_off
  else
    # Tone-caller fallback (no mic / headless): still cue audibly so the
    # operator knows the relay is live and the callee leg is streaming.
    play_go_beep
    echo "  >>> TALK NOW — the callee streams the canned scam phrase for ~10 s <<<"
    sleep 10
  fi
  ctrl_cmd '{"command":"hangup"}'
  sleep 2
  echo "  rx answers (expect 1): $(podman logs baresip-rx | grep -c '200 Answering')"
  echo "  fresh pcap: $(/usr/bin/ls -t state/spool/pcaps/*.pcap | head -1)"
}

hangup() {
  echo "=== demo_call.sh hangup ==="
  ctrl_cmd '{"command":"hangup"}'
  echo "  ✓ hangup sent"
}

case "${1:-}" in
  setup) setup ;;
  dial) dial ;;
  hangup) hangup ;;
  *) echo "Usage: bash scripts/testing/demo_call.sh {setup|dial|hangup}" >&2; exit 2 ;;
esac