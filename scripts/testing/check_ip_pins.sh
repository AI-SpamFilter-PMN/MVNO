#!/usr/bin/env bash
# ==============================================================================
# check_ip_pins.sh — assert static IP pins in docker-compose.yml are unique
# ==============================================================================
# F1-class guard (Aug 8 2026): a duplicate ipv4_address pin surfaces only at
# container start as a podman IPAM error ("requested ip address X is already
# allocated to ..."), stranding the container in Created state. This converts
# that runtime failure into a pre-commit assertion. Run before committing
# compose changes: `make check-pins`.
#
# Exit codes: 0 = all pins unique, 1 = duplicate(s) found
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PINS=$(grep -oE 'ipv4_address: [0-9.]+' docker-compose.yml | awk '{print $2}')
COUNT=$(echo "${PINS}" | grep -c . || true)
DUPS=$(echo "${PINS}" | sort | uniq -d)

if [ -n "${DUPS}" ]; then
    echo -e "\033[0;31m[check-ip-pins] FAIL: duplicate static IP pins: ${DUPS}\033[0m" >&2
    exit 1
fi

echo -e "\033[0;32m[check-ip-pins] OK: ${COUNT} static IP pins unique (docker-compose.yml)\033[0m"
