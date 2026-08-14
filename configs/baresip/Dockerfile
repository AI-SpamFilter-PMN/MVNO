# ==============================================================================
# MVNO Telecom Core — baresip UA (Real VoIP Call Rig) Dockerfile
# ==============================================================================
# Builds baresip v4.6.0 from source on Ubuntu 24.04 with the exact module set the
# LIVE_DEMO S3 rig needs (stdio, g711, uuid, menu, account, aufile, ausine,
# ctrl_tcp) + optional pulse (live host mic). Both UAs (callee streams the canned
# scam phrase; caller places the call) run as containers from this image — no
# hosted /usr/bin/baresip, no host-library mounts, no host-path Pulse dependency.
# This makes the real-call demo run identically on any Ubuntu/Debian host.
#
# Runtime:  baresip -f /cfg -s -T   (config + accounts are mounted at /cfg)
# ==============================================================================
FROM ubuntu:24.04 AS builder

# MVNO live-demo patch: aufile streams a growing WAV file (host live-mic
# feeder) instead of reading it once — makes the laptop real mic LIVE.
COPY aufile-stream.patch /tmp/aufile-stream.patch

# --- build deps for libre (re) + baresip core + the modules we select ---------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    git \
    ca-certificates \
    libssl-dev \
    libz-dev \
    libpulse-dev \
    libopus-dev \
    libspandsp-dev \
    && rm -rf /var/lib/apt/lists/*

# libre (re) — the realtime networking stack baresip links against
ARG LIBRE_VERSION=v4.9.0
RUN git clone --depth 1 --branch "${LIBRE_VERSION}" https://github.com/baresip/re.git /opt/libre \
    && cd /opt/libre \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && rm -rf /opt/libre

# baresip — container version (v4.10.0 = OpenSSL 3.x compatible; the host no
# longer needs a local baresip, the rig is fully containerized). Select exactly
# the modules the S3 rig loads.
ARG BARESIP_VERSION=v4.10.0
RUN git clone --depth 1 --branch "${BARESIP_VERSION}" https://github.com/baresip/baresip.git /opt/baresip \
    && cd /opt/baresip \
    && git apply /tmp/aufile-stream.patch \
    && cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DCMAKE_LIBRARY_PATH=/usr/local/lib \
        -DMODULES="stdio;g711;g722;opus;uuid;menu;account;aufile;ausine;ctrl_tcp;pulse" \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && rm -rf /opt/baresip

ENV LD_LIBRARY_PATH=/usr/local/lib

# baresip looks for its modules in the same place we install them
CMD ["baresip", "-f", "/cfg", "-s", "-T"]