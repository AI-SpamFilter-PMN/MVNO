# NOTE: layered on the known-good 2026-07-26 build (mvno-open5gs:2.8.0-base).
# A from-source rebuild of the same v2.8.0 tag currently yields binaries with
# regressed HTTP/2 client behavior (every NF's SBI connection to the NRF dies
# at the first ~30s heartbeat; old binaries are unaffected). Empirical matrix
# verified 2026-08-01: old client -> old NRF works, new client -> any NRF fails.
# Until that rebuild is root-caused, do NOT switch this base back to a fresh
# source build. Only the deployment bits (iproute2 + iptables + entrypoint) are layered.
FROM mvno-open5gs:2.8.0-base

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 \
    iptables && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /var/log/open5gs

ENV DB_URI=mongodb://mongodb/open5gs
EXPOSE 2152 38412 7777 9090
CMD ["/entrypoint.sh"]
