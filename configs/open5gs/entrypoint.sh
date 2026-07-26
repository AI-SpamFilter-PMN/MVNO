#!/bin/sh
set -e
COMPONENT="${COMPONENT_NAME:-nrf}"
echo "Starting Open5GS ${COMPONENT}..."
exec "open5gs-${COMPONENT}d" -c "/etc/open5gs/${COMPONENT}.yaml"
