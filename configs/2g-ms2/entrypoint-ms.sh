#!/bin/sh
# ==============================================================================
# mvno-2g-ms2 entrypoint — second 2G handset (IMSI 001010000000005).
# ==============================================================================
set -eu

virtphy -s /tmp/osmocom_l2 -d DVIRPHY:DGSMTAP:DL1C &
VIRTPHY_PID=$!
sleep 2

echo "2G MS2 virtphy up (pid $VIRTPHY_PID), starting mobile..."
exec mobile -c /etc/osmocom/mobile.cfg
