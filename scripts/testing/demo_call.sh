#!/usr/bin/env bash
# demo_call.sh — baresip call rig for LIVE_DEMO S3 (one-liner wrapper)
#
#   bash scripts/testing/demo_call.sh setup   # configs + rig containers (~15 s)
#   bash scripts/testing/demo_call.sh dial    # real call: callee streams the scam phrase; TALK NOW for ~10 s
#   bash scripts/testing/demo_call.sh hangup  # hang up (dial already hangs up; safety net)
#
# CONTAINER LIFECYCLE IS COMPOSE-MANAGED: baresip-rx/baresip-tx are real
# services in docker-compose.yml (cold-start fragmentation fix). `make up` /
# `podman compose up -d` brings them up; `make clean` removes them. This
# script only (re)writes their /cfg configs and (re)creates the containers so
# a config change takes effect — it never leaves orphaned rig containers.
#
# PORTABLE BY DESIGN: both UAs run from the packaged `mvno-baresip` image, so
# S3 needs NO host /usr/bin/baresip, no host-library mounts, and no host-model
# baresip build. The callee leg streams a real WAV through aufile (the load-
# bearing scam media) when no host Pulse socket exists, or uses the live
# laptop HW mic via pulse.so when it does (Issue 8.47 recipe). The caller leg
# uses the host PulseAudio socket when it is present (live mic) and otherwise
# falls back to a container-side tone — either way the call is real and
# RTPEngine records it.
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
# Export the pulse paths so the compose baresip services resolve to THIS
# operator's socket/cookie (compose defaults to uid 1000 / zkhattab — the
# author's rig; teammates with a different UID/username MUST have these set,
# or their baresip containers cannot reach their Pulse daemon).
export PULSE_SOCK="${PULSE_SOCK:-${PULSE_DIR}/pulse/native}"
export PULSE_DIR
export PULSE_COOKIE="${PULSE_COOKIE:-${HOME}/.config/pulse/cookie}"

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

  if [ "$PULSE_OK" -eq 1 ]; then
    cat > state/baresip/rx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module pulse.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
ctrl_tcp_listen 0.0.0.0:4444
audio_source pulse,alsa_input.pci-0000_05_00.6.analog-stereo
audio_player pulse,alsa_output.pci-0000_05_00.6.analog-stereo
EOF
  else
    cat > state/baresip/rx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module ausine.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
ctrl_tcp_listen 0.0.0.0:4444
audio_source aufile,/media/speech8k.wav
audio_player aufile,/dev/null
EOF
  fi
  cat > state/baresip/rx/accounts <<EOF
<sip:${CALLEE}@${SIP_HOST}:5060>;auth_user=${CALLEE};auth_pass=testpass;answermode=auto
EOF
  # Issue 8.48 note: `answermode=auto` alone auto-answers in the packaged
  # baresip build (verified live 2026-08-14 — gate CALL_ESTABLISHED twice);
  # if a future baresip version stops auto-answering, add `;sip_autoanswer=yes`
  # to the account line above.

  if [ "$PULSE_OK" -eq 1 ]; then
    cat > state/baresip/tx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module pulse.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
ctrl_tcp_listen 0.0.0.0:4444
audio_source pulse,alsa_input.pci-0000_05_00.6.analog-stereo
audio_player pulse,alsa_output.pci-0000_05_00.6.analog-stereo
EOF
  else
    cat > state/baresip/tx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module g722.so
module opus.so
module ausine.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
ctrl_tcp_listen 0.0.0.0:4444
audio_source ausine
audio_player aufile,/dev/null
EOF
  fi
  cat > state/baresip/tx/accounts <<EOF
<sip:${CALLER}@${SIP_HOST}:5060>;auth_user=${CALLER};auth_pass=testpass
EOF
  cp -f scripts/testing/baresip_dial.py state/baresip/tx/baresip_dial.py 2>/dev/null || true

  # Containers are COMPOSE-MANAGED (docker-compose.yml baresip-rx/baresip-tx
  # services, since the cold-start fragmentation fix): `make up` / `podman
  # compose up -d` brings them up, `make clean` removes them. This script only
  # (re)writes their /cfg configs and (re)creates the containers so a config
  # change takes effect — it never leaves orphaned rig containers behind.
  podman compose up -d baresip-rx baresip-tx 2>&1 | tail -2
  sleep 3
  local tx_src="pulse"
  [ "$PULSE_OK" -eq 1 ] && tx_src="pulse,${PULSE_SOURCE:-default}"
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
  dial) 
    CALLEE="${2:-$CALLEE}"
    dial 
    ;;
  hangup) hangup ;;
  *) echo "Usage: bash scripts/testing/demo_call.sh {setup|dial [callee]|hangup}" >&2; exit 2 ;;
esac