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

# Auto-detect container runtime (Podman or Docker)
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
else
    echo "ERROR: No container engine found (podman or docker)"
    exit 1
fi

CONTAINER="$1"
PORT="$2"
shift 2

# Execute non-interactive VTY session via container socket redirection
$CONTAINER_CMD exec "$CONTAINER" sh -c '
PORT="$1"
shift
if command -v nc >/dev/null 2>&1; then
    {
        sleep 1
        echo "enable"
        sleep 1
        for cmd in "$@"; do
            echo "$cmd"
            sleep 1
        done
    } | nc -w 3 127.0.0.1 "$PORT" 2>/dev/null
else
    bash -c "
    exec 3<>/dev/tcp/localhost/$PORT
    echo enable >&3
    sleep 1
    for cmd in \"\$@\"; do
        echo \"\$cmd\" >&3
        sleep 1
    done
    dd bs=8192 count=1 <&3 2>/dev/null
    " _ "$@"
fi
' _ "$PORT" "$@"
