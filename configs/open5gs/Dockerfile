FROM debian:bookworm AS builder
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    meson ninja-build build-essential git pkg-config ca-certificates curl cmake \
    libgnutls28-dev libgcrypt-dev libssl-dev libyaml-dev \
    libnghttp2-dev libcurl4-gnutls-dev libmongoc-dev libbson-dev \
    libsctp-dev libtins-dev libmnl-dev libtalloc-dev libmicrohttpd-dev libidn11-dev flex bison && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v2.8.0 \
    https://github.com/open5gs/open5gs.git /src

WORKDIR /src

RUN meson setup build -Dprefix=/usr && \
    ninja -C build && \
    DESTDIR=/buildroot ninja -C build install

FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgnutls30 libgcrypt20 libssl3 libyaml-0-2 libnghttp2-14 \
    libcurl3-gnutls libmongoc-1.0-0 libbson-1.0-0 libsctp1 \
    libtins4.0 libmnl0 libmicrohttpd12 libtalloc2 libidn12 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /buildroot/usr/ /usr/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && ldconfig && mkdir -p /var/log/open5gs

ENV DB_URI=mongodb://mongodb/open5gs
EXPOSE 2152 38412 7777 9090
CMD ["/entrypoint.sh"]
