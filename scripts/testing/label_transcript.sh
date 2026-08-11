#!/usr/bin/env bash
# ==============================================================================
# label_transcript.sh — Per-side (caller/callee) labeled transcript of a call
# ------------------------------------------------------------------------------
# Reads an rtpengine pcap recording and the per-leg Vosk transcripts that
# scripts/testing/live_tap.sh produced, and emits a two-sided transcript with
# each RTP leg attributed to CALLER vs CALLEE.
#
# Why this is needed (see docs/ISSUES.md, live_tap.sh header):
#   rtpengine (recording-method=pcap) rewrites BOTH call directions to the same
#   source IP, so the legs cannot be told apart by source address. live_tap
#   groups audio by rtpengine PROXY PORT (udp.dstport) to keep the two sides
#   separate for Vosk. This tool then labels each proxy port as caller or callee
#   by reading the RTCP SDES CNAME, which carries each endpoint's own SIP URI
#   (e.g. "sip:15559998888@10.89.0.23:5060"). That gives a deterministic,
#   non-hardcoded port->side mapping per call.
#
# Usage:
#   ./scripts/testing/label_transcript.sh <recording.pcap>
#
# Output (stdout, one line per side with RTP audio):
#   [CALLER (15553332211) | rtp-port 30076] said: "..."
#   [CALLEE (15559998888) | rtp-port 30068] said: "..."
#   (sides with no recognized RTCP SDES show as UNKNOWN)
# ==============================================================================
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <recording.pcap>" >&2
    exit 2
fi
P="$1"
[ -f "$P" ] || { echo "[-] not found: $P" >&2; exit 1; }

SPOOL="${SPOOL_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/state/spool}"
STEM="$(basename "$P" .pcap)"
ARCH="${SPOOL}/archived"

echo "Call: ${STEM}"

# Map each rtpengine RTP leg port -> its RTCP SDES CNAME (SIP URI of that side).
# RTCP sits on the odd port immediately above the even RTP proxy port.
map_sides() {
    for rtcp_port in $(tshark -r "$P" -Y "rtcp" -T fields -e udp.dstport 2>/dev/null | sort -n | uniq); do
        rtp_port=$(( rtcp_port - 1 ))
        cname=$(tshark -r "$P" -Y "rtcp && udp.dstport==${rtcp_port}" -V 2>/dev/null \
            | grep -oE "Text: sip:[^ ]+" | head -1 | sed 's/Text: //')
        [ -n "$cname" ] && echo "${rtp_port}|${cname}"
    done | sort -u
}

found=0
while IFS='|' read -r port cname; do
    side="UNKNOWN"
    case "$cname" in
        *15559998888*) side="CALLEE (15559998888)" ;;
        *15553332211*) side="CALLER (15553332211)" ;;
    esac
    # Concatenate any non-empty per-chunk transcripts for this leg.
    txt=""
    for f in "${ARCH}"/live-${STEM}-${port}-*.txt; do
        [ -f "$f" ] || continue
        t=$(python3 -c "import json,sys;print(json.load(open('$f')).get('text',''))" 2>/dev/null)
        # Only stitch if there is a non-blank token, else ignore silence chunks.
        if echo "$t" | grep -q '[A-Za-z0-9]'; then
            txt="$txt $t"
        fi
    done
    txt="${txt:1}"
    echo "[${side} | rtp-port ${port}] said: \"${txt}\""
    found=1
done < <(map_sides)

[ "$found" -eq 1 ] || { echo "[-] no RTCP SDES legs found in $P (was media spliced?)" >&2; exit 1; }
exit 0