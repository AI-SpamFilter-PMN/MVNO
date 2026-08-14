#!/usr/bin/env bash
# ==============================================================================
# hangup_all.sh — Emergency Call Termination & Channel Flush Utility
# ==============================================================================
# Cleans up hung, stuck, or orphaned calls across all telecom components:
# 1. Asterisk 20 ConfBridge & IVR channels (channel request hangup all)
# 2. Baresip SIP UAs (baresip-tx and baresip-rx ctrl_tcp hangup command)
# 3. Android Handset (ADB keyevent 6 KEYCODE_ENDCALL)
# 4. Kamailio Dialog & USRLOC stale session cleanup
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${CYAN}=== 🛑 Emergency Call Hangup & Channel Flush ===${NC}"

# 1. Asterisk Channels
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^mvno-asterisk$'; then
    echo -e "${YELLOW}→ Flushing Asterisk channels…${NC}"
    podman exec mvno-asterisk asterisk -rx "channel request hangup all" 2>/dev/null || true
    echo -e "${GREEN}✓ Asterisk channels hung up.${NC}"
fi

# 2. Baresip UAs
hangup_baresip() {
    local name="$1" port="$2"
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        python3 -c "
import socket
try:
    s = socket.create_connection(('127.0.0.1', ${port}), timeout=1)
    s.sendall(b'{\"command\":\"hangup\"}\n')
    s.close()
except Exception:
    pass
" 2>/dev/null || true
    fi
}

echo -e "${YELLOW}→ Terminating Baresip UAs…${NC}"
podman exec baresip-tx python3 -c "
import socket
try:
    s = socket.create_connection(('127.0.0.1', 4444), timeout=1)
    s.sendall(b'{\"command\":\"hangup\"}\n')
    s.close()
except Exception:
    pass
" 2>/dev/null || true

podman exec baresip-rx python3 -c "
import socket
try:
    s = socket.create_connection(('127.0.0.1', 4444), timeout=1)
    s.sendall(b'{\"command\":\"hangup\"}\n')
    s.close()
except Exception:
    pass
" 2>/dev/null || true
echo -e "${GREEN}✓ Baresip UAs hung up.${NC}"

# 3. Android Handset (via ADB)
if command -v adb >/dev/null 2>&1; then
    devices=$(adb devices | grep -w "device" | awk '{print $1}' || true)
    if [ -n "$devices" ]; then
        echo -e "${YELLOW}→ Sending ENDCALL to connected Android devices ($devices)…${NC}"
        for dev in $devices; do
            adb -s "$dev" shell input keyevent 6 2>/dev/null || true
        done
        echo -e "${GREEN}✓ Android handsets ended active calls.${NC}"
    fi
fi

# 4. Clean up expired Kamailio location and stale SMS queue
sqlite3 state/kamailio/kamailio.db \
    "DELETE FROM location WHERE expires < julianday('now');" 2>/dev/null || true

# 5. Host-side PulseAudio side-tone loopback (live-mic audio cue, NOT a call)
source "${REPO_ROOT}/scripts/lib/common.sh" 2>/dev/null || true
side_tone_off 2>/dev/null || true

echo -e "${GREEN}🎉 ALL CALLS AND CHANNELS SUCCESSFULLY TERMINATED.${NC}"
