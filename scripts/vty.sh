#!/bin/bash
# VTY helper — sends commands to an Osmocom VTY interface using bash TCP
# Usage: vty.sh <container> <port> <command> [command2 ...]
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
