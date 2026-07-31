# ==============================================================================
# MVNO Telecom Core — Custom Kamailio Container Dockerfile
# ==============================================================================
# From-scratch Alpine build: kamailio, kamailio-utils and kamailio-sqlite are
# installed via 'apk' from the Alpine 3.19 repositories.
# Alpine 3.19 repos ship kamailio 5.7.2
# ==============================================================================

FROM alpine:3.19

# Install kamailio packages from Alpine 3.19 repositories
RUN apk add --no-cache kamailio kamailio-utils kamailio-sqlite

# Expose SIP signaling UDP and TCP ports
EXPOSE 5060/udp 5060/tcp

# -DD: stay in foreground (container-friendly); -E: log to stderr
CMD ["kamailio", "-DD", "-E"]
