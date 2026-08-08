#!/bin/sh
# ==============================================================================
# mvno-2g-ms entrypoint — starts virtphy then the layer23 mobile handset.
# ==============================================================================
set -eu

# osmocom-bb `mobile` rejects MT SMS with RP cause 22 unless the receipt
# file exists — create it (empty) up-front so the file survives container
# recreates (it lives on the container root fs, not a volume).
mkdir -p /root/.osmocom/bb
touch /root/.osmocom/bb/sms.txt

# Start virtual PHY; it binds the L1CTL unix socket /tmp/osmocom_l2 and
# speaks GSMTAP multicast to osmo-bts-virtual on the virtual Um.
virtphy -s /tmp/osmocom_l2 -d DVIRPHY:DGSMTAP:DL1C &
VIRTPHY_PID=$!
sleep 2

echo "2G MS virtphy up (pid $VIRTPHY_PID), starting mobile..."
exec mobile -c /etc/osmocom/mobile.cfg
