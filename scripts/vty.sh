#!/usr/bin/env bash
# ==============================================================================
# vty.sh — Osmocom VTY Control Socket Automation Helper
# ==============================================================================
# Osmocom cellular daemons (osmo-msc, osmo-hlr, osmo-bsc) expose a Cisco-style
# Virtual TeleTYpe (VTY) text interface over raw TCP sockets:
# - osmo-hlr VTY: port 4258
# - osmo-msc VTY: port 4254
#
# Technical Detail:
# Uses bash built-in socket redirection `/dev/tcp/localhost/<port>` to issue
# VTY configuration and query commands non-interactively without netcat/telnet.
# ==============================================================================
set -e

CONTAINER="$1"
PORT="$2"
shift 2

podman exec "$CONTAINER" bash -c '
port='$PORT'
{
  sleep 1
  echo enable
  sleep 1
' '
  for cmd; do
    printf "  echo %q\n" "$cmd"
    printf "  sleep 1\n"
    printf "  echo %q >&3\n" "$cmd"
  done
' '
  sleep 1
} | timeout 3 bash 2>/dev/null || true
' _ "$@"

