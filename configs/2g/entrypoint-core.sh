#!/bin/sh
# ==============================================================================
# mvno-2g-core entrypoint — starts the 2G BSS stack:
#   osmo-stp -> osmo-mgw -> osmo-bsc -> osmo-bts-virtual
# ==============================================================================
set -eu

osmo-stp -c /etc/osmocom/osmo-stp.cfg &
STP_PID=$!
sleep 1

osmo-mgw -c /etc/osmocom/osmo-mgw.cfg &
MGW_PID=$!
sleep 1

osmo-bsc -c /etc/osmocom/osmo-bsc.cfg &
BSC_PID=$!
sleep 1

osmo-bts-virtual -c /etc/osmocom/osmo-bts-virtual.cfg &
BTS_PID=$!

echo "2G core running: stp=$STP_PID mgw=$MGW_PID bsc=$BSC_PID bts=$BTS_PID"
# Keep container alive; trap to forward signals
trap 'kill $BTS_PID $BSC_PID $MGW_PID $STP_PID 2>/dev/null' TERM INT
wait $BTS_PID
