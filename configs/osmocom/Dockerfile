FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q -O /usr/share/keyrings/osmocom.asc \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12/Release.key \
    && echo "deb [signed-by=/usr/share/keyrings/osmocom.asc] \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12 ./" \
    > /etc/apt/sources.list.d/osmocom.list

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    osmo-msc \
    osmo-hlr \
    && rm -rf /var/lib/apt/lists/*

VOLUME ["/etc/osmocom", "/var/lib/osmocom"]

ENV OSMO_MSC_CONFIG=/etc/osmocom/osmo-smsc.cfg

EXPOSE 2775

CMD ["osmo-msc", "-c", "/etc/osmocom/osmo-smsc.cfg"]
