#!/usr/bin/env bash
# demo_call.sh — baresip call rig for LIVE_DEMO S3 (one-liner wrapper)
#
#   bash scripts/testing/demo_call.sh setup   # speech file + baresip UAs (~15 s)
#   bash scripts/testing/demo_call.sh dial    # real call: callee streams the scam phrase; TALK NOW for ~12 s
#   bash scripts/testing/demo_call.sh hangup  # hang up (dial already hangs up; safety net)
#
# Evidence stays INLINE in the guide: podman logs baresip-rx / pcap listing /
# RTPEngine counters. This script only assembles the rig (the mechanical part).

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CALLER=15553332211
CALLEE=15559998888
SIP_HOST=10.89.0.23

build_b_array() {
  B=(-v /usr/bin/baresip:/usr/bin/baresip:ro)
  for f in /usr/lib/libbaresip.so.26 /usr/lib/libre.so.41 \
           /usr/lib/libbrotlicommon.so.1 /usr/lib/libbrotlidec.so.1 \
           /usr/lib/libbrotlienc.so.1 /usr/lib/libcrypto.so.3 \
           /usr/lib/libssl.so.3 /usr/lib/libz.so.1 /usr/lib/libzstd.so.1; do
    B+=(-v "${f}:${f}:ro")
  done
  B+=(-v /usr/lib/baresip:/usr/lib/baresip:ro)
  for f in $(ldd /usr/lib/baresip/modules/pulse.so | grep -oE '/usr/lib/[^ ]+\.so[^ ]*' | sort -u); do
    B+=(-v "${f}:${f}:ro")
  done
  B+=(-v /usr/lib64/ld-linux-x86-64.so.2:/hostld/ld-linux-x86-64.so.2:ro)
  B+=(-v /run/user/1000/pulse/native:/run/user/1000/pulse/native)
  B+=(-e PULSE_SERVER=unix:/run/user/1000/pulse/native)
}

setup() {
  echo "=== demo_call.sh setup: speech file + baresip rig ==="
  espeak-ng -v en-us "You have won a prize, call us now" -w /tmp/speech.wav
  mkdir -p state/baresip/rx state/baresip/tx
  ffmpeg -y -loglevel error -i /tmp/speech.wav -ar 8000 -ac 1 -c:a pcm_s16le \
    state/baresip/speech8k.wav

  cat > state/baresip/rx/config <<'EOF'
module_path /usr/lib/baresip/modules
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
  cat > state/baresip/tx/config <<'EOF'
module_path /usr/lib/baresip/modules
module stdio.so
module g711.so
module pulse.so
module aufile.so
module uuid.so
module_app account.so
module_app menu.so
module_app ctrl_tcp.so
audio_source pulse
audio_player pulse
EOF
  cat > state/baresip/tx/accounts <<EOF
<sip:${CALLER}@${SIP_HOST}:5060>;auth_user=${CALLER};auth_pass=testpass
EOF

  build_b_array
  podman rm -f baresip-rx baresip-tx 2>/dev/null
  podman run -d --name baresip-rx --network mvno_mvno_net --ip 10.89.0.60 \
    "${B[@]}" -v $PWD/state/baresip/rx:/cfg:z \
    -v $PWD/state/baresip/speech8k.wav:/media/speech8k.wav:ro \
    docker.io/library/ubuntu:24.04 \
    /hostld/ld-linux-x86-64.so.2 --library-path /usr/lib:/usr/lib/pulseaudio \
    /usr/bin/baresip -f /cfg -s -T
  podman run -d --name baresip-tx --network mvno_mvno_net --ip 10.89.0.61 \
    "${B[@]}" -v $PWD/state/baresip/tx:/cfg:z \
    docker.io/library/ubuntu:24.04 \
    /hostld/ld-linux-x86-64.so.2 --library-path /usr/lib:/usr/lib/pulseaudio \
    /usr/bin/baresip -f /cfg -s -T
  sleep 3
  echo "  rx registrations (expect >= 2): $(podman logs baresip-rx | grep -c '200 OK')"
  echo "  tx registrations (expect >= 2): $(podman logs baresip-tx | grep -c '200 OK')"
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
  echo "  fresh pcap: $(ls -t state/spool/pcaps/*.pcap | head -1)"
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
