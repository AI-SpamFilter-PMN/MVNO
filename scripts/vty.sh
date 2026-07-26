#!/usr/bin/env bash
# ==============================================================================
# vty.sh — Osmocom VTY Control Socket Automation Helper
# ==============================================================================
# Osmocom cellular daemons (osmo-msc, osmo-hlr) expose a Cisco-style
# Virtual TeleTYpe (VTY) text interface over raw TCP sockets:
# - osmo-hlr VTY: port 4258
# - osmo-msc VTY: port 4254
#
# Usage:
#   ./scripts/vty.sh mvno-osmo-hlr 4258 "show subscribers all"
#   ./scripts/vty.sh mvno-osmosmsc 4254 "show msc"
# ==============================================================================

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <container_name> <vty_port> <command1> [command2 ...]"
    exit 1
fi

CONTAINER="$1"
PORT="$2"
shift 2

# Execute non-interactive VTY session via native /dev/tcp socket redirection
podman exec "$CONTAINER" bash -c "
exec 3<>/dev/tcp/localhost/$PORT
echo enable >&3
sleep 1
for cmd in \"\$@\"; do
    echo \"\$cmd\" >&3
    sleep 1
done
dd bs=8192 count=1 <&3 2>/dev/null
" _ "$@"
