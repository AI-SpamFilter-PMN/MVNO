#!/bin/sh
set -e
COMPONENT="${COMPONENT_NAME:-nrf}"
echo "Starting Open5GS ${COMPONENT}..."

if [ "${COMPONENT}" = "upf" ]; then
    # Open5GS on Linux deliberately skips configuring the TUN gateway
    # (ogs_tun_set_ip() is a no-op; see src/upf/gtp-path.c "Note that Linux
    # will skip this configuration"). Wait for the UPF to create ogstun,
    # then assign the session gateway addresses + bring the link up.
    (
        i=0
        until ip link show ogstun >/dev/null 2>&1 || [ "$i" -ge 30 ]; do
            sleep 1
            i=$((i + 1))
        done
        if ip link show ogstun >/dev/null 2>&1; then
            ip addr replace 10.45.0.1/16 dev ogstun
            ip -6 addr replace 2001:db8:cafe::1/48 dev ogstun
            ip link set ogstun up
        else
            echo "ogstun never appeared; skipping TUN gateway setup"
        fi
        # N6 routing: masquerade UE (10.45.0.0/16) traffic forwarded from
        # ogstun onto the bridge so return traffic reaches the UE through the
        # UPF netns (rootless podman keeps 10.89.0.0/24 off the host, so a host
        # route is not possible; SNAT keeps the whole round-trip in-netns).
        # Idempotent: -C fails when the rule is already present.
        if command -v iptables >/dev/null 2>&1; then
            iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null \
                || iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
        else
            echo "iptables not found; skipping N6 SNAT rule"
        fi
    ) &
fi

exec "open5gs-${COMPONENT}d" -c "/etc/open5gs/${COMPONENT}.yaml"
