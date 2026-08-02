# ==============================================================================
# MVNO Cellular Core — Osmocom 2G Mobile Station (MS) Container Dockerfile
# ==============================================================================
# Builds a Debian 12 (Bookworm) container hosting the 2G handset software:
# - virtphy: virtual Layer-1 speaking GSMTAP multicast to osmo-bts-virtual
# - mobile:  layer23 MS application (OsmocomBB) providing IMSI attach + SMS
# ==============================================================================

FROM debian:12.10-slim

# Install prerequisite tools for GPG keyring fetching
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Add official Osmocom release GPG signing key and repository
RUN wget -q -O /usr/share/keyrings/osmocom.asc \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12/Release.key \
    && echo "deb [signed-by=/usr/share/keyrings/osmocom.asc] \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12 ./" \
    > /etc/apt/sources.list.d/osmocom.list

# Install OsmocomBB layer23 + virtual PHY
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    osmocom-bb-layer23 \
    osmocom-bb-virtphy \
    && rm -rf /var/lib/apt/lists/*

# Persistent volume mounts for MS configuration
VOLUME ["/etc/osmocom"]

EXPOSE 4247

CMD ["mobile", "-c", "/etc/osmocom/mobile.cfg"]
