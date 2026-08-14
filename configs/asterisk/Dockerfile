# ==============================================================================
# MVNO Telecom Core — Asterisk Media Server (Conference / Voicemail / Screening)
# ==============================================================================
# Ubuntu 24.04 container running the distro-packaged Asterisk 20.6 (chan_pjsip
# + app_confbridge + app_voicemail + IVR). Sits BEHIND Kamailio on a SIP trunk
# (port 5061) and adds the media-plane features the interception core cannot:
#   - ConfBridge conference rooms (rtpengine is a relay/NAT anchor, NOT an MCU)
#   - voicemail + IVR + call-screening dialplan
# Accept/decline stays native SIP (200/486/603) — no work needed.
#
# Why Ubuntu (not Debian): `asterisk` was DROPPED from Debian 12 main (only the
# sound packages remain) but is packaged in Ubuntu 24.04 (20.6.0). This also
# matches the project decision doc ("Ubuntu apt install asterisk — zero custom
# build") and teammates' Ubuntu laptops. The host runs CachyOS (Arch) — the
# container image runs identically on both, no host distro packages, no ABI
# mixing (same pattern as the baresip rig, which is also ubuntu:24.04).
#
# Runtime:  asterisk -f -vvv   (foreground; configs bind-mounted at /etc/asterisk)
# ==============================================================================
FROM ubuntu:24.04

RUN apt-get update \
    # NOTE: voicemail (app_voicemail) is BUILT INTO the asterisk package in
    # Ubuntu 24.04 — there is no asterisk-voicemail package. MOH sounds are
    # not packaged separately either (asterisk-moh-opsound does not exist in
    # noble); asterisk-core-sounds-en provides the prompts we play.
    && apt-get install -y --no-install-recommends \
        asterisk \
        asterisk-config \
        asterisk-core-sounds-en \
        procps \
        vim-tiny \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/lib/asterisk/sounds /var/spool/asterisk /var/log/asterisk \
    && (id asterisk 2>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/asterisk asterisk) \
    # Asterisk looks for its XML documentation at /var/lib/asterisk/documentation
    # (the Ubuntu package seeds it via a first-boot systemd unit that never runs
    # in a container). Without it stasis init fails and Asterisk exits:
    #   "Stasis initialization failed. ASTERISK EXITING!"
    && ln -s /usr/share/asterisk/documentation /var/lib/asterisk/documentation \
    && chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk 2>/dev/null || true

# Configs are bind-mounted from ./configs/asterisk at /etc/asterisk; keep the
# packaged sample dir out of the way so our files win.
RUN rm -f /etc/asterisk/*.conf.sample 2>/dev/null || true

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENTRYPOINT ["/entrypoint.sh"]
