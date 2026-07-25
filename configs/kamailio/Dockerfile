# ==============================================================================
# MVNO Telecom Core — Custom Kamailio Container Dockerfile
# ==============================================================================
# Extends standard Alpine-based Kamailio image with the 'kamailio-utils' package,
# which provides necessary http_client.so and xhttp_prom.so modules.
# ==============================================================================

FROM alpine:3.19

# Install kamailio packages from Alpine 3.19 repositories
RUN apk add --no-cache kamailio kamailio-utils kamailio-sqlite

# Expose SIP signaling UDP and TCP ports
EXPOSE 5060/udp 5060/tcp

CMD ["kamailio", "-DD", "-E"]
