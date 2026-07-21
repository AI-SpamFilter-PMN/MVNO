FROM alpine:3.19
RUN apk add --no-cache kamailio kamailio-sqlite kamailio-tls kamailio-sctp kamailio-utils
COPY configs/kamailio/kamailio.cfg /etc/kamailio/
VOLUME ["/etc/kamailio"]
EXPOSE 5060/udp 5060/tcp
CMD ["kamailio", "-f", "/etc/kamailio/kamailio.cfg", "-DD"]
