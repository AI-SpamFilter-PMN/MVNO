#!/usr/bin/env bash
# ==============================================================================
# launch_wireshark.sh — Dedicated Standalone Wireshark GUI Launcher for MVNO
# ==============================================================================
# Launches Wireshark GUI detached, pre-configured with:
#   1. Multi-interface capture on 'any' (captures host LAN, Wi-Fi, loopback, and containers)
#   2. Hardware RTP packet decoder (G.711u / PCMU on UDP 10000-20000)
#   3. Display filter for SIP, SMPP, RTP, and REST API interception traffic
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== 🦈 Launching MVNO Wireshark Packet Capture GUI ===${NC}"

if ! command -v wireshark >/dev/null 2>&1; then
    echo -e "${RED}✗ Wireshark is not installed. Please install it via: sudo apt install wireshark / sudo pacman -S wireshark-qt${NC}" >&2
    exit 1
fi

if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    echo -e "${YELLOW}⚠ No graphical DISPLAY or WAYLAND_DISPLAY found.${NC}"
    echo "To inspect pcaps post-hoc on a headless machine, use:"
    echo "  tshark -r \"\$(bash scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')\" -d udp.port==10000-20000,rtp -Y 'sip || rtp || smpp'"
    exit 0
fi

# Detect GUI platform
plat="xcb"
[ -n "${WAYLAND_DISPLAY:-}" ] && plat="wayland"
xa=":"
[ "${plat}" = "xcb" ] && xa="${XAUTHORITY:-$HOME/.Xauthority}"

# Check dumpcap capture permissions
if ! timeout 2 dumpcap -i lo -a duration:1 -w /tmp/mvno-ws-perm.pcap >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: dumpcap may lack raw capture permissions.${NC}"
    echo "  If capture is empty, run: sudo setcap cap_net_raw,cap_net_admin+eip \$(command -v dumpcap)"
fi
rm -f /tmp/mvno-ws-perm.pcap

# Interface: capture 'any' to see container virtual eth, wifi wlan0 (Android phone), and localhost
iface="any"
cap_filter="port 5060 or port 5061 or port 2775 or port 2076 or port 8080 or port 8081 or port 8000 or (udp portrange 10000-20000)"

mkdir -p state/logs

# Launch Wireshark GUI in background
setsid nohup env QT_QPA_PLATFORM="$plat" DISPLAY="${DISPLAY:-}" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XAUTHORITY="$xa" \
    wireshark -k -i "$iface" -f "$cap_filter" \
    -d "udp.port==10000-20000,rtp" -Y "sip || smpp || rtp || http" >> state/logs/wireshark-gui.log 2>&1 &

WS_PID=$!
sleep 1

if kill -0 "$WS_PID" 2>/dev/null; then
    echo -e "${GREEN}✓ Wireshark GUI launched successfully (PID ${WS_PID}, Interface: ${iface})!${NC}"
    echo -e "  ${CYAN}• Active Filters:${NC} SIP (5060/5061), RTP (10000-20000), SMPP (2775/2076), REST (8080/8081/8000)"
    echo -e "  ${CYAN}• Display Filter:${NC} sip || smpp || rtp || http"
    echo -e "  ${CYAN}• Log output:${NC}     state/logs/wireshark-gui.log"
else
    echo -e "${RED}✗ Wireshark GUI failed to launch. Check state/logs/wireshark-gui.log${NC}" >&2
    exit 1
fi
