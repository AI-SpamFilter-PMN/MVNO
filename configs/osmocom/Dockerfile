# ==============================================================================
# MVNO Cellular Core — Osmocom MSC & HLR Container Dockerfile
# ==============================================================================
# Builds a Debian 12 (Bookworm) container hosting Osmocom C-based cellular core:
# - osmo-msc: Mobile Switching Center (handles SMPP 3.4 server on port 2775)
# - osmo-hlr: Home Location Register (SQLite subscriber database storage)
# ==============================================================================

FROM debian:bookworm-slim

# Install prerequisite tools for GPG keyring fetching
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Add official Osmocom release GPG signing key and repository
RUN wget -q -O /usr/share/keyrings/osmocom.asc \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12/Release.key \
    && echo "deb [signed-by=/usr/share/keyrings/osmocom.asc] \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12 ./" \
    > /etc/apt/sources.list.d/osmocom.list

# Install Osmocom cellular binaries
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    osmo-msc \
    osmo-hlr \
    && rm -rf /var/lib/apt/lists/*

# Persistent volume mounts for VTY configuration and SQLite HLR database
VOLUME ["/etc/osmocom", "/var/lib/osmocom"]

ENV OSMO_MSC_CONFIG=/etc/osmocom/osmo-smsc.cfg

# Expose SMPP 3.4 server TCP port for ESME connection from telecom-api
EXPOSE 2775

CMD ["osmo-msc", "-c", "/etc/osmocom/osmo-smsc.cfg"]

