#!/bin/sh
# ==============================================================================
# Asterisk entrypoint — create runtime dirs (needs root) then drop to the
# asterisk user and run the daemon in the foreground.
# ==============================================================================
set -e

mkdir -p /var/run/asterisk /var/log/asterisk /var/spool/asterisk /tmp
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk 2>/dev/null || true

exec su -s /bin/sh asterisk -c "exec asterisk -f -vvv"
