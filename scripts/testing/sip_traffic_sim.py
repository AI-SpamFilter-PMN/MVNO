#!/usr/bin/env python3
"""
SIP Traffic Simulator for MVNO Interception Core
Generates real SIP REGISTER & INVITE dialogs through Kamailio & RTPEngine

Flexible transport paths (same script, different --host/--port):
  - 2G/IMS path (default):  python3 sip_traffic_sim.py
    -> host loopback 127.0.0.1:5060 -> Kamailio (canonical host port)
  - 5G SA path:             python3 sip_traffic_sim.py --host 10.89.0.23 --port 5060
    -> from inside a UE container, with the kamailio /32 routed via the
       uesimtun0 interface, so SIP traverses the 5G user plane
       (UE tun -> N3 GTP-U -> UPF ogstun -> bridge -> Kamailio)

RTP media plane (real G.711 PCMU through rtpengine, record-call spooling):
  - UAS role:    python3 sip_traffic_sim.py --uas 15559998888 --bind-ip <ip> \
                   --listen-port 5070 --host 10.89.0.23 --port 5060
                 (registers the callee, answers INVITE with an SDP, counts RTP)
  - Caller role: python3 sip_traffic_sim.py --rtp 6 --caller 15551234567 \
                   --callee 15559998888 --bind-ip <ip> --listen-port 5070 \
                   --host 10.89.0.23 --port 5060
                 (digest INVITE -> ACK -> streams PCMU RTP for N seconds -> BYE)
"""
import argparse
import hashlib
import math
import signal
import socket
import struct
import sys
import threading
import time

# Registry of registration Call-IDs keyed by the bound UDP socket's fileno, so
# the UAS can deregister itself with the SAME Call-ID it registered with.
# (socket.socket objects disallow arbitrary attribute assignment on some builds.)
_REG_CALLIDS = {}


def calculate_digest_response(username, realm, password, method, uri, nonce):
    ha1 = hashlib.md5(f"{username}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    return hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()


def _extract_nonce(resp_text, header):
    for line in resp_text.split("\r\n"):
        if line.lower().startswith(header.lower() + ":"):
            parts = line.split('nonce="')
            if len(parts) > 1:
                return parts[1].split('"')[0]
    return ""


def deregister_subscriber(username, password, host="127.0.0.1", port=5060, contact="*",
                           bind_ip="127.0.0.1", listen_port=5070):
    """Digest-authenticated deregister: REGISTER carrying a specific Contact with
    Expires: 0 removes ONLY that one binding; contact="*" clears ALL bindings.
    contact filtering preserves co-registered live UAs (e.g. the baresip-rx rig
    sharing the AOR) from being wiped by a stale 5G-path probe deregister.
    (Issue 8.37 pattern — the demo leaves stale registrations behind.)

    IMPORTANT (5G-path stale-binding fix): the socket MUST be bound to the SAME
    (bind_ip, listen_port) the UAS registered from. Kamailio runs
    force_rport()+fix_nated_contact() on every REGISTER, so a deregister from an
    ephemeral source port is NAT-rewritten to a source that doesn't match the
    stored binding and the specific contact is silently NOT removed (200 OK with
    the binding still live). Binding to the UAS's own source port makes
    fix_nated_contact() yield the identical stored address, so the binding is
    actually removed. Loopback bind_ip (legacy path) stays unbound, matching
    register_subscriber()'s handling.

    Returns True on SIP/2.0 200 OK."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    if not bind_ip.startswith("127."):
        s.bind((bind_ip, listen_port))
    call_id = f"dereg-{username}-{int(time.time())}@127.0.0.1"

    def build_reg(cseq, auth=""):
        auth_hdr = f"Authorization: {auth}\r\n" if auth else ""
        contact_hdr = "*" if contact == "*" else f"<{contact}>"
        return (
            f"REGISTER sip:localhost:{port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-drg{cseq}-{username}\r\n"
            f"From: <sip:{username}@localhost>;tag=tag-drg-{username}\r\n"
            f"To: <sip:{username}@localhost>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: {cseq} REGISTER\r\n"
            f"Contact: {contact_hdr}\r\n"
            f"{auth_hdr}"
            f"Expires: 0\r\n"
            f"Content-Length: 0\r\n\r\n"
        )

    s.sendto(build_reg(1).encode(), (host, port))
    try:
        resp1, _ = s.recvfrom(4096)
        resp1_str = resp1.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] Deregister failed for {username}: {e}")
        s.close()
        return False
    nonce = _extract_nonce(resp1_str, "www-authenticate")
    if not nonce:
        print(f"[-] Deregister failed for {username}: No nonce received")
        s.close()
        return False
    digest = calculate_digest_response(username, "localhost", password, "REGISTER",
                                       f"sip:localhost:{port}", nonce)
    auth = f'Digest username="{username}", realm="localhost", nonce="{nonce}", uri="sip:localhost:{port}", response="{digest}"'
    s.sendto(build_reg(2, auth).encode(), (host, port))
    try:
        resp2, _ = s.recvfrom(4096)
        resp2_str = resp2.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] SIP DEREGISTER response error: {e}")
        s.close()
        return False
    if "200 OK" in resp2_str:
        print(f"[+] SIP DEREGISTER 200 OK for {username} (all bindings cleared)")
        s.close()
        return True
    print(f"[-] SIP DEREGISTER rejected for {username}:\n{resp2_str}")
    s.close()
    return False


def deregister_self(sock, username, password, host, port, contact):
    """Deregister a SPECIFIC contact using the SAME socket + Call-ID that the
    UAS registered with. This is the only form Kamailio's registrar removes a
    bare-contact binding by: save() matches the existing binding on (AOR, Call-ID),
    so a deregister with a fresh Call-ID (see deregister_subscriber) or the
    wildcard would either be ignored or wipe co-registered UAs (baresip-rx).
    Returns True on SIP/2.0 200 OK. socket must be the bound registration socket."""
    call_id = _REG_CALLIDS.get(sock.fileno())
    if not call_id:
        print(f"[-] deregister_self: no Call-ID registered for socket {sock.fileno()}")
        return False
    s = sock
    s.settimeout(3)

    def build_reg(cseq, auth=""):
        auth_hdr = f"Authorization: {auth}\r\n" if auth else ""
        bind_ip, listen_port = s.getsockname()
        contact_hdr = "*" if contact == "*" else f"<{contact}>"
        return (
            f"REGISTER sip:localhost:{port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-sd{cseq}-{username}\r\n"
            f"From: <sip:{username}@localhost>;tag=tag-sd-{username}\r\n"
            f"To: <sip:{username}@localhost>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: {cseq} REGISTER\r\n"
            f"Contact: {contact_hdr}\r\n"
            f"{auth_hdr}"
            f"Expires: 0\r\n"
            f"Content-Length: 0\r\n\r\n"
        )

    # The registration already consumed CSeq 1 (challenge) and 2 (auth), and
    # deregister_self reuses the SAME Call-ID, so Kamailio's registrar rejects a
    # replayed/invalid CSeq number. Start the deregister CSeq strictly above the
    # registration's max (use an offset that stays valid across retries).
    base_cseq = 100
    s.sendto(build_reg(base_cseq).encode(), (host, port))
    try:
        resp1, _ = s.recvfrom(4096)
        resp1_str = resp1.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] Self-deregister failed for {username}: {e}")
        return False
    nonce = _extract_nonce(resp1_str, "www-authenticate")
    if not nonce:
        print(f"[-] Self-deregister failed for {username}: No nonce received")
        return False
    digest = calculate_digest_response(username, "localhost", password, "REGISTER",
                                       f"sip:localhost:{port}", nonce)
    auth = f'Digest username="{username}", realm="localhost", nonce="{nonce}", uri="sip:localhost:{port}", response="{digest}"'
    s.sendto(build_reg(base_cseq + 1, auth).encode(), (host, port))
    try:
        resp2, _ = s.recvfrom(4096)
        resp2_str = resp2.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] SIP self-DEREGISTER response error: {e}")
        return False
    if "200 OK" in resp2_str:
        print(f"[+] Self-DEREGISTER 200 OK for {username} contact {contact} (Call-ID-matched)")
        return True
    print(f"[-] Self-DEREGISTER rejected for {username}:\n{resp2_str}")
    return False


def register_subscriber(username, password, host="127.0.0.1", port=5060,
                        bind_ip="127.0.0.1", listen_port=5070):
    """Register via a socket bound to (bind_ip, listen_port) so the source
    address matches the Contact header. Kamailio's fix_nated_contact() then
    leaves the contact intact and forwarded requests reach the listen port.
    Loopback bind_ip (legacy 5G-path mode) stays unbound — sending from a
    127.0.0.1-bound socket to an external proxy raises EINVAL.
    Returns the open socket (kept alive for inbound requests), or None."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    if not bind_ip.startswith("127."):
        s.bind((bind_ip, listen_port))
    call_id = f"reg-{username}-{int(time.time())}@127.0.0.1"
    _REG_CALLIDS[s.fileno()] = call_id   # expose so the UAS can deregister itself with the same Call-ID

    def build_reg(cseq, auth=""):
        auth_hdr = f"Authorization: {auth}\r\n" if auth else ""
        return (
            f"REGISTER sip:localhost:{port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-reg{cseq}-{username}\r\n"
            f"From: <sip:{username}@localhost>;tag=tag-{username}\r\n"
            f"To: <sip:{username}@localhost>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: {cseq} REGISTER\r\n"
            f"Contact: <sip:{username}@{bind_ip}:{listen_port}>\r\n"
            f"{auth_hdr}"
            f"Expires: 3600\r\n"
            f"Content-Length: 0\r\n\r\n"
        )

    s.sendto(build_reg(1).encode(), (host, port))
    try:
        resp1, _ = s.recvfrom(4096)
        resp1_str = resp1.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] Registration failed for {username}: {e}")
        s.close()
        return None
    nonce = _extract_nonce(resp1_str, "www-authenticate")
    if not nonce:
        print(f"[-] Registration failed for {username}: No nonce received")
        s.close()
        return None
    digest = calculate_digest_response(username, "localhost", password, "REGISTER",
                                       f"sip:localhost:{port}", nonce)
    auth = f'Digest username="{username}", realm="localhost", nonce="{nonce}", uri="sip:localhost:{port}", response="{digest}"'
    s.sendto(build_reg(2, auth).encode(), (host, port))
    try:
        resp2, _ = s.recvfrom(4096)
        resp2_str = resp2.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] SIP REGISTER response error: {e}")
        s.close()
        return None
    if "200 OK" in resp2_str:
        print(f"[+] SIP REGISTER 200 OK for subscriber {username}")
        return s
    print(f"[-] SIP REGISTER rejected for {username}:\n{resp2_str}")
    s.close()
    return None


G722_OPT = "9"   # payload type 9 = G.722/16000 (HD wideband)


def _sdp(c_ip, media_port, codec="pcmu"):
    """Build the local SDP offer/answer.

    codec="pcmu" -> G.711 &mu;-law only (historic default).
    codec=g722 or g722+pcmu -> offer wideband G.722 along with PCMU fallback, so a
    real UA/phone (e.g. Android MizuDroid/Linphone, which default to G.722) can
    negotiate HD over the rtpengine relay. rtpengine is codec-agnostic (no
    transcoding config), so the negotiated payload type passes through.
    """
    if codec == "g722":
        return (
            "v=0\r\n"
            f"o=user1 53655765 23536879 IN IP4 {c_ip}\r\n"
            "s=-\r\n"
            f"c=IN IP4 {c_ip}\r\n"
            "t=0 0\r\n"
            f"m=audio {media_port} RTP/AVP {G722_OPT} 0\r\n"
            f"a=rtpmap:{G722_OPT} G722/16000\r\n"
            "a=rtpmap:0 PCMU/8000\r\n"
        )
    return (
        "v=0\r\n"
        f"o=user1 53655765 23536879 IN IP4 {c_ip}\r\n"
        "s=-\r\n"
        f"c=IN IP4 {c_ip}\r\n"
        "t=0 0\r\n"
        f"m=audio {media_port} RTP/AVP 0\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
    )


def _parse_sdp(resp_text):
    ip, port = None, None
    for line in resp_text.split("\r\n"):
        if line.startswith("c=IN IP4 "):
            ip = line.split()[-1]
        elif line.startswith("m=audio "):
            port = int(line.split()[1])
    return ip, port


def _record_routes(resp_text):
    routes = []
    for line in resp_text.split("\r\n"):
        if line.lower().startswith("record-route:"):
            routes.append("Route: " + line.split(":", 1)[1].strip())
    return routes


def _to_tag(resp_text):
    for line in resp_text.split("\r\n"):
        if line.lower().startswith("to:"):
            if "tag=" in line:
                return line.split("tag=", 1)[1].split(";")[0].strip('"')
    return ""


def _parse_contact(resp_text):
    for line in resp_text.split("\r\n"):
        if line.lower().startswith("contact:"):
            uri = line.split(":", 1)[1].split("<")[-1].split(">")[0].strip()
            if uri:
                return uri
    return ""


def ulaw_encode(x):
    x = max(-32768, min(32767, int(x)))
    sign = 0x80 if x < 0 else 0
    if x < 0:
        x = -x
    if x > 32635:
        x = 32635
    x += 0x84
    exp = 7
    while exp > 0 and (x >> (exp + 3)) == 0:
        exp -= 1
    mant = (x >> (exp + 3)) & 0x0F
    if exp > 0:
        mant &= ~0x08
    return (~(sign | (exp << 4) | mant)) & 0xFF


def _rtp_packet(seq, ts, payload, ssrc=0x5A5A5A5A):
    return struct.pack(">BBHII", 0x80, 0, seq & 0xFFFF, ts, ssrc) + payload


def send_rtp(sock, addr, seconds, freq=440.0, amp=12000):
    """Stream G.711 PCMU RTP (50 pps, 20 ms frames) for `seconds`."""
    ssrc = int(time.time()) & 0xFFFFFFFF
    seq, ts = 0, 0
    tone = bytes(ulaw_encode(amp * math.sin(2 * math.pi * freq * i / 8000.0))
                 for i in range(160))
    silence = b"\xff" * 160
    sent = 0
    end = time.time() + seconds
    while time.time() < end:
        payload = tone if sent < 20 else silence
        sock.sendto(_rtp_packet(seq, ts, payload, ssrc), addr)
        sent += 1
        seq += 1
        ts += 160
        time.sleep(0.02)
    return sent


def _wait_for(resp_sock, deadline, wanted, log=True):
    """Read datagrams until one contains `wanted` (or the deadline)."""
    resp_sock.settimeout(max(0.1, deadline - time.time()))
    while time.time() < deadline:
        try:
            data, _ = resp_sock.recvfrom(65535)
        except socket.timeout:
            return None
        txt = data.decode("utf-8", errors="ignore")
        if log and txt.startswith("SIP/2.0"):
            print(f"    <- {txt.split(chr(13) + chr(10))[0]}")
        if wanted in txt:
            return txt
    return None


def run_uas(msisdn, password, host, port, bind_ip, listen_port, rtp_seconds=0, codec="pcmu",
            reg_contact=None):
    """Register a callee and answer INVITEs; count RTP received on the media port.

    reg_contact: the contact Kamailio stores for this UAS (e.g. the UPF-SNAT'd
    'sip:<msisdn>@10.89.0.14:5070' on the 5G path). When set, the UAS deregisters
    ITS OWN Call-ID-scoped binding on SIGTERM (pkill) so no stale usrloc contact
    is left behind while co-registered UAs (baresip-rx) are preserved."""
    sip = register_subscriber(msisdn, password, host, port, bind_ip, listen_port)
    if sip is None:
        return False
    sip.settimeout(60)
    media = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    media.bind((bind_ip, listen_port + 1))
    media.settimeout(1)
    media_port = listen_port + 1

    def _self_cleanup(signum, frame):
        # pkill sends SIGTERM: deregister OUR OWN binding (same Call-ID) before
        # dying, so Kamailio actually removes it (matches on Call-ID) and we do
        # NOT wipe co-registered UAs (baresip-rx has a different Call-ID).
        try:
            deregister_self(sip, msisdn, password, host, port,
                            reg_contact or f"sip:{msisdn}@{bind_ip}:{listen_port}")
        except Exception as e:
            print(f"[UAS] self-deregister error on SIGTERM: {e}")
        sys.exit(0)

    if reg_contact:
        signal.signal(signal.SIGTERM, _self_cleanup)
        signal.signal(signal.SIGINT, _self_cleanup)

    rx_bytes = [0]
    def media_loop():
        while True:
            try:
                data, _ = media.recvfrom(4096)
            except socket.timeout:
                continue
            if len(data) >= 12 and data[0] >> 6 == 2:
                rx_bytes[0] += len(data) - 12

    t = threading.Thread(target=media_loop, daemon=True)
    t.start()
    tx_peer = [None]
    def rtp_sender():
        while tx_peer[0] is None:
            time.sleep(0.2)
        sent = send_rtp(media, tx_peer[0], rtp_seconds)
        print(f"[UAS] outgoing RTP sent: {sent} packets to {tx_peer[0]}")

    t2 = threading.Thread(target=rtp_sender, daemon=True)
    t2.start()

    print(f"[UAS] registered {msisdn}, listening {bind_ip}:{listen_port} "
          f"(media {bind_ip}:{media_port})")
    while True:
        try:
            data, src = sip.recvfrom(65535)
        except socket.timeout:
            continue
        txt = data.decode("utf-8", errors="ignore")
        first = txt.split("\r\n", 1)[0]
        print(f"[UAS] <- {first}")
        hdrs = {}
        body = ""
        for line in txt.split("\r\n")[1:]:
            if not line.strip():
                break
            k, _, v = line.partition(":")
            hdrs.setdefault(k.strip().lower(), []).append(v.strip())
        if "content-length" in hdrs:
            clen = int(hdrs["content-length"][0])
            body = txt.split("\r\n\r\n", 1)[1][:clen] if "\r\n\r\n" in txt else ""
        via = "\r\n".join("Via: " + v for v in hdrs.get("via", []))
        call_id = hdrs.get("call-id", [""])[0]
        cseq = hdrs.get("cseq", ["0"])[0]
        from_hdr = hdrs.get("from", [""])[0]
        to_hdr = hdrs.get("to", [""])[0]

        def reply(status_line, extra=""):
            rr = "".join(f"Record-Route: {v}\r\n" for v in hdrs.get("record-route", []))
            msg = (
                f"{status_line}\r\n{via}\r\n{rr}"
                f"From: {from_hdr}\r\nTo: {to_hdr};tag=uas-{int(time.time())}\r\n"
                f"Call-ID: {call_id}\r\nCSeq: {cseq}\r\n"
                f"{extra}Content-Length: 0\r\n\r\n"
            )
            sip.sendto(msg.encode(), src)

        if txt.startswith("INVITE "):
            offer_ip, offer_port = _parse_sdp(body)
            if offer_ip and offer_port:
                tx_peer[0] = (offer_ip, offer_port)
            reply("SIP/2.0 100 Trying")
            reply("SIP/2.0 180 Ringing")
            sdp = _sdp(bind_ip, media_port, codec)
            reply("SIP/2.0 200 OK",
                  f"Contact: <sip:{msisdn}@{bind_ip}:{listen_port}>\r\n"
                  f"Content-Type: application/sdp\r\n"
                  f"Content-Length: {len(sdp)}\r\n\r\n{sdp}")
        elif txt.startswith("BYE "):
            reply("SIP/2.0 200 OK")
            print(f"[UAS] call ended; RTP payload bytes received: {rx_bytes[0]}")
        elif txt.startswith("ACK "):
            pass


def run_call_with_media(caller, callee, password, host, port, bind_ip, listen_port,
                        rtp_seconds, codec="pcmu"):
    """Full dialog: digest INVITE -> ACK -> RTP stream -> BYE."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind_ip, listen_port))
    s.settimeout(10)
    call_id = f"call-{int(time.time())}@mvno"
    sdp = _sdp(bind_ip, listen_port + 1, codec)
    uri = f"sip:{callee}@localhost:{port}"

    def build_invite(auth=""):
        auth_hdr = f"Authorization: {auth}\r\n" if auth else ""
        return (
            f"INVITE {uri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-inv-{caller}\r\n"
            f"From: <sip:{caller}@localhost>;tag=tag-inv-{caller}\r\n"
            f"To: <sip:{callee}@localhost>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: 1 INVITE\r\n"
            f"Contact: <sip:{caller}@{bind_ip}:{listen_port}>\r\n"
            f"{auth_hdr}"
            f"Content-Type: application/sdp\r\n"
            f"Content-Length: {len(sdp)}\r\n\r\n"
            f"{sdp}"
        )

    s.sendto(build_invite().encode(), (host, port))
    resp1 = _wait_for(s, time.time() + 8, "Proxy-Authenticate")
    if not resp1:
        print("[-] no 407 challenge for INVITE")
        return False
    nonce = _extract_nonce(resp1, "proxy-authenticate")
    if not nonce:
        print("[-] INVITE challenge: no nonce")
        return False
    digest = calculate_digest_response(caller, "localhost", password, "INVITE", uri, nonce)
    auth = f'Digest username="{caller}", realm="localhost", nonce="{nonce}", uri="{uri}", response="{digest}"'
    s.sendto(build_invite(auth).encode(), (host, port))
    resp2 = _wait_for(s, time.time() + 12, "200 OK")
    if not resp2:
        print("[-] INVITE never answered (no 200 OK)")
        return False
    media_ip, media_port = _parse_sdp(resp2)
    if not (media_ip and media_port):
        print("[-] no media SDP in 200 OK")
        return False
    print(f"[+] call answered; media -> {media_ip}:{media_port}")

    routes = _record_routes(resp2)
    route_hdr = "".join(f"{r}\r\n" for r in routes)
    tag = _to_tag(resp2)
    contact = _parse_contact(resp2)
    dialog_uri = contact if contact else uri
    ack = (
        f"ACK {dialog_uri} SIP/2.0\r\n"
        f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-ack-{caller}\r\n"
        f"From: <sip:{caller}@localhost>;tag=tag-inv-{caller}\r\n"
        f"To: <sip:{callee}@localhost>;tag={tag}\r\n"
        f"Call-ID: {call_id}\r\n"
        f"CSeq: 1 ACK\r\n"
        f"{route_hdr}"
        f"Content-Length: 0\r\n\r\n"
    )
    s.sendto(ack.encode(), (host, port))

    sent = send_rtp(s, (media_ip, media_port), rtp_seconds)
    print(f"[+] RTP media sent: {sent} packets to {media_ip}:{media_port}")

    bye = (
        f"BYE {dialog_uri} SIP/2.0\r\n"
        f"Via: SIP/2.0/UDP {bind_ip}:{listen_port};branch=z9hG4bK-bye-{caller}\r\n"
        f"From: <sip:{caller}@localhost>;tag=tag-inv-{caller}\r\n"
        f"To: <sip:{callee}@localhost>;tag={tag}\r\n"
        f"Call-ID: {call_id}\r\n"
        f"CSeq: 2 BYE\r\n"
        f"{route_hdr}"
        f"Content-Length: 0\r\n\r\n"
    )
    s.sendto(bye.encode(), (host, port))
    try:
        s.settimeout(3)
        resp, _ = s.recvfrom(4096)
        print(f"    <- {resp.decode('utf-8', errors='ignore').split(chr(13) + chr(10))[0]}")
    except socket.timeout:
        print("    (no BYE response within 3s — session will close via timer)")
    return True


def send_sip_invite(caller, callee, password, host="127.0.0.1", port=5060, codec="pcmu"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(10)
    call_id = f"call-{int(time.time())}@127.0.0.1"
    sdp = _sdp("127.0.0.1", 30002, codec)

    def build_invite(auth_header=""):
        auth = f"Authorization: {auth_header}\r\n" if auth_header else ""
        return (
            f"INVITE sip:{callee}@localhost:{port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-inv-{caller}\r\n"
            f"From: <sip:{caller}@localhost>;tag=tag-inv-{caller}\r\n"
            f"To: <sip:{callee}@localhost>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: 1 INVITE\r\n"
            f"Contact: <sip:{caller}@127.0.0.1:5070>\r\n"
            f"{auth}"
            f"Content-Type: application/sdp\r\n"
            f"Content-Length: {len(sdp)}\r\n\r\n"
            f"{sdp}"
        )

    s.sendto(build_invite().encode(), (host, port))
    try:
        resp1, _ = s.recvfrom(4096)
        resp1_str = resp1.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[-] SIP INVITE 407 challenge error: {e}")
        s.close()
        return False
    nonce = _extract_nonce(resp1_str, "proxy-authenticate")
    if not nonce:
        print(f"[-] SIP INVITE challenge failed: no nonce received:\n{resp1_str}")
        s.close()
        return False
    uri = f"sip:{callee}@localhost:{port}"
    digest = calculate_digest_response(caller, "localhost", password, "INVITE", uri, nonce)
    auth_header = (f'Digest username="{caller}", realm="localhost", nonce="{nonce}", '
                   f'uri="{uri}", response="{digest}"')
    s.sendto(build_invite(auth_header).encode(), (host, port))
    deadline = time.time() + 8
    final_line = "No Response"
    while time.time() < deadline:
        try:
            s.settimeout(max(0.1, deadline - time.time()))
            resp2, _ = s.recvfrom(4096)
        except socket.timeout:
            break
        except Exception as e:
            print(f"[-] SIP INVITE recv error: {e}")
            s.close()
            return False
        resp2_str = resp2.decode("utf-8", errors="ignore")
        first_line = resp2_str.split("\r\n")[0] if resp2_str else "No Response"
        print(f"[+] SIP INVITE Response for {caller}->{callee}: {first_line}")
        code = first_line.split(" ")[1] if " " in first_line else "000"
        final_line = first_line
        if code.startswith(("2", "3", "4", "5", "6")):
            resp2_str_lower = resp2_str.lower()
            if "200 ok" not in resp2_str_lower:
                print(f"[-] INVITE not answered with 200 OK (got: {first_line})")
                s.close()
                return False
            s.close()
            return True
    print(f"[-] INVITE not answered with 200 OK (got: {final_line})")
    s.close()
    return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MVNO SIP traffic simulator")
    parser.add_argument("--host", default="127.0.0.1", help="Kamailio target host (127.0.0.1 = 2G/IMS path via host port; 10.89.0.23 = 5G SA path from a UE container)")
    parser.add_argument("--port", type=int, default=5060, help="Kamailio target port (5060 = canonical host port, same as container)")
    parser.add_argument("--caller", default="15551234567", help="Calling subscriber")
    parser.add_argument("--callee", default="15557654321", help="Called subscriber (registered by this script)")
    parser.add_argument("--password", default="testpass", help="SIP digest password (auth_db)")
    parser.add_argument("--bind-ip", default="127.0.0.1", help="Local bind IP (container IP on mvno_net for media tests)")
    parser.add_argument("--listen-port", type=int, default=5070, help="Local UDP listen port (media on port+1)")
    parser.add_argument("--uas", default=None, metavar="MSISDN", help="UAS role: register MSISDN and answer INVITEs, counting RTP")
    parser.add_argument("--reg-contact", default=None, metavar="SIP_URI", help="(UAS role) the contact Kamailio stores (e.g. UPF-SNAT'd sip:<msisdn>@10.89.0.14:5070 on the 5G path); enables Call-ID-scoped self-deregister on SIGTERM")
    parser.add_argument("--rtp", type=int, default=0, metavar="SECONDS", help="Caller role with real RTP media for N seconds")
    parser.add_argument("--deregister", action="store_true", help="Digest-authenticated Contact: * Expires: 0 deregister of --callee (clears ALL usrloc bindings for the AoR; binds --bind-ip:--listen-port so fix_nated_contact matches the stored binding)")
    parser.add_argument("--deregister-contact", default=None, metavar="SIP_URI",
                        help="Digest-authenticated Expires: 0 deregister of --callee for a SPECIFIC Contact URI only "
                             "(e.g. sip:15559998888@10.89.0.14:5070). Unlike --deregister it does NOT wipe other "
                             "co-registered bindings (e.g. a live baresip-rx sharing the AoR). ",
                        )
    parser.add_argument("--codec", default="pcmu", choices=["pcmu", "g722"],
                        help="Codec to offer/answer: pcmu (G.711u, default), g722 (wideband G.722/16000 + PCMU fallback)")
    args = parser.parse_args()

    if args.deregister:
        ok = deregister_subscriber(args.callee, args.password, args.host, args.port,
                                   bind_ip=args.bind_ip, listen_port=args.listen_port)
        sys.exit(0 if ok else 1)

    if args.deregister_contact:
        ok = deregister_subscriber(args.callee, args.password, args.host, args.port,
                                   contact=args.deregister_contact,
                                   bind_ip=args.bind_ip, listen_port=args.listen_port)
        sys.exit(0 if ok else 1)

    if args.uas:
        ok = run_uas(args.uas, args.password, args.host, args.port,
                     args.bind_ip, args.listen_port, args.rtp, args.codec,
                     reg_contact=args.reg_contact)
        sys.exit(0 if ok else 1)

    if args.rtp > 0:
        print(f"=== Full IMS call with RTP media ({args.caller} -> {args.callee}, {args.rtp}s, {args.codec}) ===")
        ok = run_call_with_media(args.caller, args.callee, args.password,
                                 args.host, args.port, args.bind_ip,
                                 args.listen_port, args.rtp, args.codec)
        sys.exit(0 if ok else 1)

    print(f"=== Registering Callee {args.callee} (via {args.host}:{args.port}) ===")
    reg_ok = register_subscriber(args.callee, args.password, args.host, args.port,
                                 args.bind_ip, args.listen_port)
    time.sleep(1)
    print("=== Sending Real SIP INVITE Call (digest-authenticated) ===")
    inv_ok = send_sip_invite(args.caller, args.callee, args.password, args.host, args.port, args.codec)
    if not (reg_ok and inv_ok):
        sys.exit(1)
