# Multi-stage Dockerfile for UERANSIM 3.2.6 on Ubuntu 24.04 (GLIBC 2.38)
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    g++ \
    libsctp-dev \
    lksctp-tools \
    iproute2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
RUN git clone -b v3.2.6 --depth 1 https://github.com/aligungr/UERANSIM.git /workspace/UERANSIM

WORKDIR /workspace/UERANSIM
RUN find src -type f \( -name "*.hpp" -o -name "*.cpp" \) -exec sed -i '1s/^/#include <string>\n#include <vector>\n#include <iostream>\n#include <sstream>\n#include <cstdint>\n#include <cstdio>\n#include <cstring>\n#include <stdexcept>\n/' {} + || true
RUN cmake . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-w" && make -C build -j$(nproc)

FROM ubuntu:24.04 AS runner

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsctp1 \
    libstdc++6 \
    iproute2 \
    iptables \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/bin
COPY --from=builder /workspace/UERANSIM/build/nr-gnb /usr/local/bin/nr-gnb
COPY --from=builder /workspace/UERANSIM/build/nr-ue /usr/local/bin/nr-ue
COPY --from=builder /workspace/UERANSIM/build/nr-cli /usr/local/bin/nr-cli

CMD ["nr-gnb", "--help"]
