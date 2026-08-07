#!/usr/bin/env bash
# demo_call.sh — baresip call rig for LIVE_DEMO S3 (one-liner wrapper)
#
#   bash scripts/testing/demo_call.sh setup   # speech file + baresip UAs (~15 s)
#   bash scripts/testing/demo_call.sh dial    # real call: callee streams the scam phrase; TALK NOW for ~12 s
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

CALLER=15553332211
CALLEE=15559998888
SIP_HOST=10.89.0.23
IMAGE="${BARESIP_IMAGE:-mvno-baresip:1.0.0}"
NET=("--network" "mvno_mvno_net")

# Portable host PulseAudio socket (XDG runtime dir; fall back to uid-based path).
PULSE_OK=0
PULSE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -S "${PULSE_DIR}/pulse/native" ]; then
  PULSE_OK=1
fi

module_path() {
  # baresip image installs modules under /usr/local/lib/baresip/modules
  echo "module_path /usr/local/lib/baresip/modules"
}

setup() {
  echo "=== demo_call.sh setup: speech file + baresip rig ==="
  espeak-ng -v en-us "You have won a prize, call us now" -w /tmp/speech.wav
  mkdir -p state/baresip/rx state/baresip/tx
  ffmpeg -y -loglevel error -i /tmp/speech.wav -ar 8000 -ac 1 -c:a pcm_s16le \
    state/baresip/speech8k.wav

  cat > state/baresip/rx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module ausine.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
audio_source aufile,/media/speech8k.wav
EOF
  cat > state/baresip/rx/accounts <<EOF
<sip:${CALLEE}@${SIP_HOST}:5060>;auth_user=${CALLEE};auth_pass=testpass;answermode=auto
EOF
  # Caller leg: use the live host mic when a Pulse socket exists, else a
  # container-side speech tone (portable fallback — still a real call).
  local tx_src="ausine"
  if [ "$PULSE_OK" -eq 1 ]; then
    tx_src="pulse"
  fi
  cat > state/baresip/tx/config <<EOF
$(module_path)
module stdio.so
module g711.so
module ausine.so
module aufile.so
module pulse.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
audio_source ${tx_src}
EOF
  cat > state/baresip/tx/accounts <<EOF
<sip:${CALLER}@${SIP_HOST}:5060>;auth_user=${CALLER};auth_pass=testpass
EOF

  podman rm -f baresip-rx baresip-tx 2>/dev/null
  if [ "$PULSE_OK" -eq 1 ]; then
    podman run -d --name baresip-rx "${NET[@]}" --ip 10.89.0.60 \
      -v $PWD/state/baresip/rx:/cfg:z \
      -v $PWD/state/baresip/speech8k.wav:/media/speech8k.wav:ro \
      "${IMAGE}" >/dev/null
    podman run -d --name baresip-tx "${NET[@]}" --ip 10.89.0.61 \
      -v $PWD/state/baresip/tx:/cfg:z \
      -v "${PULSE_DIR}/pulse/native:${PULSE_DIR}/pulse/native" \
      -e "PULSE_SERVER=unix:${PULSE_DIR}/pulse/native" \
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
  echo "  caller audio source: ${tx_src}"
  echo "  ✓ rig ready — paste: bash scripts/testing/demo_call.sh dial"
}

ctrl_cmd() {
  local cmd="$1"
  podman exec baresip-tx bash -c "exec 3<>/dev/tcp/127.0.0.1/4444; \
    printf '${#cmd}:${cmd},' >&3; timeout 2 cat <&3"
}

dial() {
  echo "=== demo_call.sh dial: ${CALLER} -> ${CALLEE} ==="
  ctrl_cmd "{\"command\":\"dial\",\"params\":\"sip:${CALLEE}@${SIP_HOST}:5060\"}"
  echo "  >>> TALK NOW — the callee streams the canned scam phrase for ~12 s <<<"
  sleep 12
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