#!/usr/bin/env bash
# ==============================================================================
# pcap_opus_legs.sh — decode Opus (phone/Linphone PT96) RTP legs from an
# rtpengine pcap into 16 kHz mono WAVs in the Vosk spool root, so the in-process
# NativeVoskService (telecom-api) transcribes each leg to a side-labeled
# transcript. Complements live_tap.sh --once (the PCMU/G.711 certified path).
#
# Why (see docs/ISSUES.md #8.46 + this file):
#   - The Android Linphone negotiates Opus PT96 (rtpmap:96 opus/48000/2) and its
#     RTP genuinely reaches rtpengine on the UFW-allowed 10000-20000 range (live
#     tshark ground truth: phone -> 192.168.100.93:<proxy-port>).
#   - live_tap.sh's Opus branch uses `ffmpeg -f opus`, and this host's ffmpeg has
#     NO raw-Opus demuxer (only libopus codec + ogg/oga), so Opus legs yield
#     "no PCMU RTP payloads" / empty — the phone leg never gets transcribed.
#   - Proven decode for tapped RTP-Opus here is GStreamer:
#         udpsrc(caps=application/x-rtp,encoding-name=OPUS) ! rtpopusdepay
#         ! opusdec ! audioresample ! audio/x-raw,rate=16000,channels=1 ! wavenc
#     (validated against a real 212KB phone pcap -> 22s WAV; and against an
#     Opus-RTP-synthesized scam phrase -> Vosk "your bank account have been like
#     please confirm your detailed out").
#   - rtpengine (recording-method=pcap) rewrites BOTH directions to one source, so
#     legs are split by udp.dstport (each side's rtpengine proxy port), and
#     caller/callee is resolved from the RTCP SDES CNAME (the SIP URI each side
#     puts in its RTCP) — the same deterministic key label_transcript.sh uses.
#
# Usage:
#   ./scripts/testing/pcap_opus_legs.sh <recording.pcap>
#   Env: SPOOL_DIR (default state/spool), UDP_BASE (default 51040; used to bind,
#        may collide on concurrent use).
#   Output: state/spool/opus-<stem>-<port>.wav  (Vosk spool root)
#   Vosk then writes state/spool/archived/opus-<stem>-<port>.txt automatically.
#   Exit: 0 if >=1 leg decoded, 1 otherwise. Prints per-leg side + wav.
# ==============================================================================
set -euo pipefail

for tool in tshark gst-launch-1.0 python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "[-] '$tool' missing" >&2; exit 1; }
done

[ $# -eq 1 ] || { echo "Usage: $0 <recording.pcap>" >&2; exit 1; }
P="$1"
[ -f "$P" ] || { echo "[-] not found: $P" >&2; exit 1; }

SPOOL="${SPOOL_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/state/spool}"
mkdir -p "$SPOOL"
STEM="$(basename "$P" .pcap)"
UDP_BASE="${UDP_BASE:-51040}"

# --- RTCP SDES CNAME -> side (SIP identity is the deterministic key) ---------
side_for() {
    local rtcp_port=$(( $1 + 1 ))
    local cname
    cname=$(tshark -r "$P" -Y "rtcp && udp.dstport==${rtcp_port}" -V 2>/dev/null \
        | grep -oE "Text: sip:[^ ]+" | head -1 | sed 's/Text: //')
    case "$cname" in
        *15559998888*) echo "callee(15559998888)" ;;
        *15553332211*) echo "caller(15553332211)" ;;
        *15551234567*) echo "caller(linphone)" ;;
        *) [ -n "$cname" ] && echo "side=$(basename "$cname")" || echo "unknown" ;;
    esac
}

# --- has opus payload on this leg? (PT 96/111) -------------------------------
has_opus() {
    local PORT="$1"
    tshark -r "$P" -Y "udp.dstport==${PORT}" -T fields -e data.data 2>/dev/null \
        | awk 'BEGIN{c=0} $0 ~ /^[0-9a-fA-F]+$/ { h=substr($0,3,2); pt=strtonum("0x"h); if (pt==96||pt==111) c++ } END{print c+0}'
}

# --- replay one leg's RTP to a local UDP port while gst decodes it -----------
decode_leg() {
    local PORT="$1" UDP="$2" OUT="$3"
    # udpsrc never sees EOS, so the gst process is bounded with `timeout`; it
    # flushes wavenc on SIGTERM leaving a valid/truncated WAV Vosk can read.
    # The 8s cap is tuned to a ~4s scam phrase on an 8kHz/48kHz leg + margin.
    timeout -k 2 8 gst-launch-1.0 -q udpsrc port="$UDP" \
        caps="application/x-rtp,media=audio,encoding-name=OPUS,payload=96,clock-rate=48000,channels=2" \
        ! rtpopusdepay ! opusdec ! audioresample ! audio/x-raw,rate=16000,channels=1 \
        ! wavenc ! filesink location="$OUT" >/dev/null 2>&1 &
    local gspid=$!
    # Wait for gst to bind before replaying (else packets drop before preroll).
    sleep 1
    tshark -r "$P" -Y "udp.dstport==${PORT}" -T fields -e data.data 2>/dev/null \
        | grep -E '^[0-9a-fA-F]+$' \
        | python3 -c "
import socket, sys, time
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for line in sys.stdin:
    try: b=bytes.fromhex(line.strip())
    except ValueError: continue
    if not b: continue
    s.sendto(b, ('127.0.0.1', $UDP))
    time.sleep(0.010)
" 2>/dev/null
    wait "$gspid" 2>/dev/null || true
    [ -s "$OUT" ] || rm -f "$OUT"
}

written=0
for PORT in $(tshark -r "$P" -Y "udp" -T fields -e udp.dstport 2>/dev/null | sort -n | uniq); do
    [ -n "$PORT" ] || continue
    # Even dstport (RTP) + has opus payload
    if [ $(( PORT % 2 )) -eq 0 ] && [ "$(has_opus "$PORT")" -gt 0 ]; then
        side=$(side_for "$PORT")
        OUT="${SPOOL}/opus-${STEM}-${PORT}.wav"
        rm -f "$OUT"
        UDP=$(( UDP_BASE + (PORT % 400) ))
        decode_leg "$PORT" "$UDP" "$OUT"
        if [ -s "$OUT" ]; then
            echo "[+] $side leg (rtp-port $PORT): $OUT"
            written=1
        else
            echo "[-] $side leg (rtp-port $PORT): decode failed (no audio)"
        fi
    fi
done

[ "$written" -eq 1 ] || { echo "[-] no Opus legs decoded from $P" >&2; exit 1; }
exit 0