# ==============================================================================
# MVNO Telecom Core — Custom Kamailio Container Dockerfile
# ==============================================================================
# Extends standard Alpine-based Kamailio image with the 'kamailio-utils' package,
# which provides necessary http_client.so and xhttp_prom.so modules.
# ==============================================================================

FROM kamailio/kamailio:5.7-alpine

# Install kamailio-utils package from Alpine 3.19 apk repositories
RUN apk add --no-cache kamailio-utils

# Expose SIP signaling UDP and TCP ports
EXPOSE 5060/udp 5060/tcp

CMD ["kamailio", "-DD", "-E"]
