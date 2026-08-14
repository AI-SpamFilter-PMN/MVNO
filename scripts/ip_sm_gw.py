#!/usr/bin/env python3
"""
IP-SM-GW bridge (TS 23.204 / TS 24.011) for the MVNO rain-soak SRE drills.

Dual-leg SMS interworking between the 2G SMS core and the 5G/IMS SIP core:
  - 2G -> 5G: poll the OsmoSMSC queue (state/hlr/smsc.db) for rows whose
    dest_addr is a 5G MSISDN (not attached to the 2G VLR), digest-authenticate
    as that 2G MSISDN, and send a SIP MESSAGE via Kamailio (which intercepts +
    relays to the registered 5G UE). Mark the row delivered (sent=now).
  - 5G -> 2G: REGISTER the 2G MSISDNs with Kamailio (Contact = this bridge) so
    lookup("location") succeeds, then listen for SIP MESSAGEs destined
    to those 2G subscribers and inject them into OsmoSMSC via SMPP submit_sm.

Governance: no external libraries — stdlib only.
All configuration is environment-overridable.
"""

import hashlib
import json
import os
import re
import socket
import struct
import sqlite3
import sys
import time

SMSC_DB = os.environ.get("SMSC_DB", "/var/lib/osmocom/smsc.db")
HLR_DB = os.environ.get("HLR_DB", "/var/lib/osmocom/hlr.db")
KAMAILIO_HOST = os.environ.get("KAMAILIO_HOST", "10.89.0.23")
KAMAILIO_PORT = int(os.environ.get("KAMAILIO_PORT", "5060"))
SMPP_HOST = os.environ.get("SMPP_HOST", "10.89.0.49")
SMPP_PORT = int(os.environ.get("SMPP_PORT", "2775"))
SIP_BIND = os.environ.get("SIP_BIND", "0.0.0.0")
SIP_PORT = int(os.environ.get("SIP_PORT", "5090"))
REALM = os.environ.get("REALM", "localhost")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "3"))
PASSWORD = os.environ.get("SIP_PASSWORD", "testpass")

MSISDN_2G = {
    m.strip()
    for m in os.environ.get("MSISDN_2G", "15554443322,15557778888").split(",")
}
MSISDN_5G = {
    m.strip()
    for m in os.environ.get("MSISDN_5G", "15551234567,15557654321,15559998888").split(",")
}


def log(tag, msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [{tag}] {msg}", flush=True)


# -----------------------------------------------------------------------------
# Lightweight Prometheus telemetry (stdlib only — no external deps)
# -----------------------------------------------------------------------------
import http.server
import threading

METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))

_METRICS_LOCK = threading.Lock()
_METRICS = {
    "mvno_bridge_sms_2g_to_5g_total": 0,
    "mvno_bridge_sms_5g_to_2g_total": 0,
    "mvno_bridge_sms_attempts_total": 0,
    "mvno_bridge_sms_failures_total": 0,
}

_START = time.time()

# -----------------------------------------------------------------------------
# Functional health: per-AoR registration state (the 5G->2G leg). /health and
# the mvno_bridge_2g_aor_registered gauge reflect the LAST successful REGISTER,
# so a bridge that is alive but whose 2G registrations have died (the "silent
# Up" hole) is visible to a healthcheck / watchdog instead of masquerading as
# healthy. The health threshold tracks the REFRESH cadence (not the SIP
# Expires window) so a persistent REGISTER failure turns /health 503 within
# ~2.5 min instead of the 35 min the Expires would otherwise allow.
# -----------------------------------------------------------------------------
REG_EXPIRES = int(os.environ.get("REGISTER_EXPIRES", "1800"))
# Unconditional registration refresh cadence. The registrations live in
# Kamailio usrloc MEMORY (the sqlite location mirror runs db_mode=2 write-back
# and is not a live signal). A Kamailio restart or an external deregister
# (Expires:0, e.g. the cockpit's stale-AoR cleanup) silently kills the 5G->2G
# route in usrloc while this bridge's /health would still say OK. Refreshing
# every 60s bounds that silent window to ~1 min (vs 15 min at the old 900s)
# and re-REGISTERing self-heals usrloc — so /health stays an honest signal.
REGISTER_REFRESH = float(os.environ.get("REGISTER_REFRESH", "60"))
# Health threshold: healthy iff refreshed within a small multiple of the
# cadence (default 2.5x = 150s) — a failing REGISTER shows 503 quickly.
REG_HEALTH_MAX_AGE = float(os.environ.get("REGISTER_HEALTH_MAX_AGE", str(REGISTER_REFRESH * 2.5)))
# Per-AoR last-REGISTER timestamps, written by the main loop and read by the
# HTTP thread. Float assignment/read is atomic under the CPython GIL, so no
# lock is needed (same rationale as the plain _METRICS reads).
_REG_LAST = {m: 0.0 for m in MSISDN_2G}


def _mark_registered(msisdn):
    _REG_LAST[msisdn] = time.time()


def _aor_healthy(msisdn):
    t = _REG_LAST.get(msisdn, 0.0)
    return bool(t) and (time.time() - t) <= REG_HEALTH_MAX_AGE


def _render_health():
    now = time.time()
    ages = {
        m: (round(now - _REG_LAST[m], 1) if _REG_LAST[m] else None)
        for m in sorted(MSISDN_2G)
    }
    stale = {m: a for m, a in ages.items() if a is None or a > REG_HEALTH_MAX_AGE}
    body = json.dumps(
        {
            "status": "ok" if not stale else "degraded",
            "registered": {m: a is not None for m, a in ages.items()},
            "age_seconds": ages,
            "threshold_seconds": REG_HEALTH_MAX_AGE,
            "uptime_seconds": round(now - _START, 1),
        },
        indent=2,
    ).encode()
    return (200 if not stale else 503), body


def incr(name, by=1):
    with _METRICS_LOCK:
        _METRICS[name] = _METRICS.get(name, 0) + by


def _render_metrics():
    lines = []
    for name in sorted(_METRICS):
        with _METRICS_LOCK:
            val = _METRICS[name]
        lines.append(f"# TYPE {name} counter")
        lines.append(f"{name} {val}")
    for m in sorted(MSISDN_2G):
        lines.append("# TYPE mvno_bridge_2g_aor_registered gauge")
        lines.append(f'mvno_bridge_2g_aor_registered{{msisdn="{m}"}} {1 if _aor_healthy(m) else 0}')
    lines.append("# TYPE mvno_bridge_uptime_seconds gauge")
    lines.append(f"mvno_bridge_uptime_seconds {time.time() - _START:.3f}")
    return "\n".join(lines) + "\n"


class _MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.rstrip("/") or "/"
        if path in ("/metrics", "/"):
            body = _render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/health":
            code, body = _render_health()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *a):
        pass


def start_metrics_server():
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", METRICS_PORT), _MetricsHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log("METRICS", f"listening on 0.0.0.0:{METRICS_PORT}/metrics")



# -----------------------------------------------------------------------------
# SQLite / SMSC queue helpers
# -----------------------------------------------------------------------------
def connect(db_path):
    con = sqlite3.connect(db_path, timeout=10)
    con.execute("PRAGMA busy_timeout=5000")
    con.row_factory = sqlite3.Row
    return con


MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "5"))


def fetch_pending_2g_to_5g(con):
    cur = con.execute(
        """
        SELECT id, src_addr, dest_addr, text, user_data, data_coding_scheme
          FROM SMS
         WHERE sent IS NULL
           AND deliver_attempts < ?
           AND dest_addr IN ({})
    """.format(
            ",".join("?" * len(MSISDN_5G))
        ),
        (MAX_ATTEMPTS, *sorted(MSISDN_5G)),
    )
    return cur.fetchall()


def mark_attempt(con, row_id):
    con.execute(
        "UPDATE SMS SET deliver_attempts = deliver_attempts + 1 WHERE id = ?",
        (row_id,),
    )
    con.commit()


def mark_delivered(con, row_id):
    con.execute(
        "UPDATE SMS SET sent = datetime('now'), deliver_attempts = deliver_attempts + 1 WHERE id = ?",
        (row_id,),
    )
    con.commit()


# -----------------------------------------------------------------------------
# GSM 7-bit (GSM 03.38) unpacking — decode SMSC `user_data` into plain text when
# the SQLite `text` column is empty. SMPP/VTY-injected SMS store the payload as
# packed septets in `user_data`; the real 2G MS path populates `text` instead.
# -----------------------------------------------------------------------------
_GSM7_ALPHABET = (
    "@\u00a3$\u00a5\u00e8\u00e9\u00f9\u00ec\u00f2\u00c7\n\u00d8\u00f8\r\u00c5\u00e5"
    "\u0394_\u03a6\u0393\u039b\u03a9\u03a0\u03a8\u03a3\u0398\u039e\uff1b\u00c6\u00e6"
    "\u00df\u00c9 !\"#\u00a4%&'()*+,-./0123456789:;<=>?\u00a1"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ\u00c4\u00d6\u00d1\u00dc\u00a7\u00bf"
    "abcdefghijklmnopqrstuvwxyz\u00e4\u00f6\u00f1\u00fc\u00e0"
)
_GSM7_EXT = {
    0x0A: "\f", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
    0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "\u20ac",
}


# Reverse (char -> septet) maps, built lazily so module import stays free of
# side effects.
def _char_to_septet():
    return {c: i for i, c in enumerate(_GSM7_ALPHABET)}


def _ext_to_septet():
    return {c: i for i, c in _GSM7_EXT.items()}


def gsm7_encode(text):
    """Encode Unicode text into a GSM 03.38 7-bit packed octet string.

    Each character is mapped to its default-alphabet septet; extended-table
    characters (``[ ] { } \\ | ~ ^ €``) are encoded as the 0x1B escape
    followed by the extension-table septet. Characters outside GSM 03.38 are
    replaced with ``?``. The septets are packed LSB-first with no gap,
    zero-padded to the final octet — the exact inverse of :func:`gsm7_decode`.
    """
    char_to_septet = _char_to_septet()
    ext_to_septet = _ext_to_septet()
    septets = []
    for ch in text:
        if ch in char_to_septet:
            septets.append(char_to_septet[ch])
        elif ch in ext_to_septet:
            septets.append(0x1B)
            septets.append(ext_to_septet[ch])
        else:
            septets.append(char_to_septet["?"])
    out = bytearray()
    val = 0
    bits = 0
    for s in septets:
        val |= s << bits
        bits += 7
        while bits >= 8:
            out.append(val & 0xFF)
            val >>= 8
            bits -= 8
    if bits > 0:
        out.append(val & 0xFF)  # zero-pad the final partial octet
    return bytes(out)


def gsm7_decode(packed, n_septets=None):
    """Unpack a GSM 7-bit encoded octet string into Unicode text.

    GSM 03.38 7-bit LSB-first packing: consecutive septets are packed into
    octets with no gap, so a septet may span two octets. We extract septets
    from the octet stream in 7-bit steps (bit-offset method).

    Two defects in the ORIGINAL implementation are fixed here (both regression
    -tested in scripts/test_ip_sm_gw.py):

    1. Truncation: the old ``if bits >= 7`` flush after a *single* emit per
       octet dropped the trailing septet whenever the accumulator climbed past
       7 bits, corrupting every message longer than ~15 chars ("you have won a
       prize" lost its final "e"; a 160-char message lost its last char).
    2. Spurious trailing septet: without the true septet count (UDL) the last
       octet's zero-padding is indistinguishable from a real septet, and a
       naive decode emitted a bogus trailing ``@`` for messages whose length
       was ≡ 7 (mod 8).

    The zero-padding in the final partial octet is only decodable from a real
    trailing ``@`` (septet 0x00) when the true septet count is known, so the
    buffer alone cannot disambiguate them. Callers that know the exact septet
    count — e.g. from an SMPP SM_length / GSM 03.38 UDL — MUST pass
    ``n_septets`` to decode exactly that many septets and drop the padding
    (see gsm7_decode(bytes, n_septets) at the SMPP submit path). Without it we
    emit every fully-contained septet and never guess, preferring to preserve
    content over a silent drop.
    """
    septets = []
    total_septets = (8 * len(packed) + 6) // 7  # ceil(8m/7) = max septets held
    bit = 0
    for _ in range(total_septets):
        if bit + 7 > 8 * len(packed):
            break
        byte_i, shift = divmod(bit, 8)
        take = 8 - shift
        if take >= 7:
            septet = (packed[byte_i] >> shift) & 0x7F
        else:
            lo = (packed[byte_i] >> shift) & ((1 << take) - 1)
            hi = packed[byte_i + 1] & ((1 << (7 - take)) - 1)
            septet = lo | (hi << take)
        septets.append(septet)
        bit += 7
    # Exact septet count supplied (e.g. from an SMPP SM_length / UDL): honour it
    # (unambiguous — no padding heuristics). Callers without a known count get
    # every fully-contained septet; a trailing zero-padding septet can only be
    # disambiguated from a literal final '@' via the UDL, so we never guess.
    if n_septets is not None:
        septets = septets[:n_septets]
    out = []
    i = 0
    while i < len(septets):
        c = septets[i]
        i += 1
        if c == 0x1B and i < len(septets):  # escape to extension table
            out.append(_GSM7_EXT.get(septets[i], ""))
            i += 1
        else:
            out.append(_GSM7_ALPHABET[c] if c < len(_GSM7_ALPHABET) else "?")
    return "".join(out)



# -----------------------------------------------------------------------------
# SMPP 3.4 BIND_TRANSCEIVER + SUBMIT_SM helpers (no external libs)
# -----------------------------------------------------------------------------
def _recv_exact(sock, n):
    """Read exactly ``n`` bytes from a blocking stream socket.

    ``sock.recv`` on a TCP socket may return fewer bytes than requested (the
    stream can be fragmented arbitrarily). The old single ``s.recv(1024)``
    call let a partial read (header split across two IP segments) fall straight
    into ``struct.unpack(">II", resp[4:12])`` and raise a ``struct.error`` —
    a live SMPP framing crash. Loop until the full 16-byte SMPP PDU header
    (command_length/command_id/command_status/sequence_number) is assembled;
    the status checks below read only ``resp[4:12]`` (command_id + status), so
    16 bytes of header is sufficient. Regression-tested in
    scripts/test_ip_sm_gw.py::SmppSubmitSmTest.test_fragmented_recv_reassembles.
    """
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break  # peer closed
        buf += chunk
    return bytes(buf)


def smpp_submit_sm(host, port, sender, recipient, message):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((host, port))
    bind_body = (
        b"smsclient\x00"   # system_id
        b"password\x00"     # password
        b"\x00"             # system_type
        b"\x34"             # interface_version (SMPP 3.4)
        b"\x00"             # addr_ton
        b"\x00"             # addr_npi
        b"\x00"             # address_range
    )
    bind_hdr = struct.pack(">IIII", 16 + len(bind_body), 0x00000009, 0, 1)
    s.sendall(bind_hdr + bind_body)
    resp = _recv_exact(s, 16)
    cmd_id, status = struct.unpack(">II", resp[4:12])
    if status != 0 or cmd_id != 0x80000009:
        s.close()
        raise RuntimeError(f"SMPP BIND failed: status=0x{status:08X}")
    log("SMPP", "BIND_TRANSCEIVER OK")
    # Drain the bind_response body (OsmoSMSC appends a 1-byte empty system_id,
    # making the PDU 17 bytes). If left in the socket, that stray octet shifts
    # the SUBMIT_SM response parse one byte right and yields a bogus non-zero
    # status (0x04000000) even though the SMS is stored and delivered.
    bind_clen = struct.unpack(">I", resp[:4])[0]
    if bind_clen > 16:
        _recv_exact(s, bind_clen - 16)

    sender_b = sender.encode() + b"\x00"
    recipient_b = recipient.encode() + b"\x00"
    # SMS default alphabet (data_coding=0x00): OsmoSMSC expects UNPACKED 7-bit
    # characters in short_message (one octet per septet), with sm_length = the
    # character count. It packs to GSM-7 septets itself for the 2G radio path.
    # Sending pre-packed bytes (gsm7_encode) double-encodes: OsmoSMSC treats the
    # packed octets as literal text and the 2G MS displays raw packed garbage.
    # Verified empirically via smpp_ab_test.py: packed -> garbled, ascii -> clean.
    msg_b = message.encode("ascii", errors="replace")
    submit_body = (
        b"\x00"
        + b"\x01\x01"
        + sender_b
        + b"\x01\x01"
        + recipient_b
        + b"\x00\x00\x00"
        + b"\x00"
        + b"\x00"
        + b"\x00\x00\x00\x00"
        + bytes([len(msg_b)])
        + msg_b
    )
    submit_hdr = struct.pack(">IIII", 16 + len(submit_body), 0x00000004, 0, 2)
    s.sendall(submit_hdr + submit_body)
    resp = _recv_exact(s, 16)
    s.close()
    resp_cmd, resp_status = struct.unpack(">II", resp[4:12])
    if resp_status != 0:
        raise RuntimeError(f"SMPP SUBMIT_SM failed: status=0x{resp_status:08X}")
    log("SMPP", f"SUBMIT_SM OK {sender} -> {recipient}")


# -----------------------------------------------------------------------------
# SIP / digest helpers (subset of ims_terminal.py)
# -----------------------------------------------------------------------------
def digest_response(username, realm, password, method, uri, nonce):
    ha1 = hashlib.md5(f"{username}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    return hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()


def parse_nonce(resp_text, header):
    if not isinstance(resp_text, str) or not resp_text.strip():
        return None
    for line in resp_text.split("\r\n"):
        if line.lower().startswith(header.lower() + ":"):
            m = re.search(r'nonce="([^"]+)"', line)
            if m:
                return m.group(1)
    return None


def reply_ok(req_text, sock, host, port):
    # Normalize line endings FIRST: some embedded/Mizudroid-style clients emit
    # bare-LF SIP. Splitting on CRLF only would collapse the whole request into
    # ONE line, so the 200 OK would carry NO Via/From/Call-ID headers — Kamailio
    # cannot match the transaction and retransmits the MESSAGE forever (the SMS
    # still gets delivered; the sender just never sees the final 200).
    # Observed live 2026-08-14 with a bare-LF MizuDroid-style MESSAGE.
    text = req_text.replace("\r\n", "\n")
    lines = text.split("\n")
    vias = [ln.strip().split(":", 1)[1].strip() for ln in lines if ln.lower().startswith("via:")]
    headers = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    via_block = "".join(f"Via: {v}\r\n" for v in vias)
    reply = (
        "SIP/2.0 200 OK\r\n"
        f"{via_block}"
        f"From: {headers.get('from', '')}\r\n"
        f"To: {headers.get('to', '')}\r\n"
        f"Call-ID: {headers.get('call-id', '')}\r\n"
        f"CSeq: {headers.get('cseq', '')}\r\n"
        "Content-Length: 0\r\n\r\n"
    )
    sock.sendto(reply.encode(), (host, port))


def _extract_msisdn(header_value):
    """Pull the numeric MSISDN out of a From/To header VALUE.

    Real SIP stacks vary widely (all RFC 3261-legal):
      - bracket forms: `From: <sip:1555..@..>` vs bare `From: sip:1555..@..`
      - display names: `From: "Jane Doe" <sip:+1555..@..>`
      - schemes: `sip:`, `tel:`, and `sip:+` international prefixes
      - header case: `from:` / `From:` / `FROM:` (some embedded/Mizudroid-style
        stacks emit lowercase header names)
    Prefer an explicit sip:/tel: URI number (so a display name containing
    digits, e.g. "Agent 007", never wins over the real address), then fall
    back to any 8+ digit run for bare-number headers.
    """
    if not header_value:
        return None
    m = re.search(r'(?:sip:|tel:)\+?(\d+)', header_value, re.I)
    if m:
        return m.group(1)
    m = re.search(r'\+?(\d{8,})', header_value)
    return m.group(1) if m else None


def parse_sip_message(req_text):
    if not isinstance(req_text, str) or not req_text.strip():
        return None, None, ""
    # `<` is OPTIONAL: RFC 3261 allows both `From: <sip:..>` and the bare
    # `From: sip:..` form. Android Linphone sends `To: sip:15554443322@localhost`
    # WITHOUT angle brackets — a strict `<sip:` regex silently dropped every
    # phone-originated message (recipient=None -> not in MSISDN_2G -> no 200,
    # Kamailio timed out and sent 408). Observed live 2026-08-14.
    #
    # Normalize line endings first: some clients (embedded/Mizudroid-style)
    # emit bare-LF SIP without CRLF. Searching on a normalized copy keeps the
    # body split reliable for both conventions.
    text = req_text.replace("\r\n", "\n")
    body_m = re.search(r"\n\n(.*)", text, re.S)
    body = body_m.group(1).strip() if body_m else ""
    from_h = to_h = None
    for line in text.split("\n"):
        low = line.lower()
        if low.startswith("from:") and from_h is None:
            from_h = line[5:].strip()
        elif low.startswith("to:") and to_h is None:
            to_h = line[3:].strip()
    return _extract_msisdn(from_h), _extract_msisdn(to_h), body


def is_typing_indicator(req_text):
    """True if this is an RFC 3994 is-composing (typing) notification, not an
    actual SMS. Android Linphone sends these as SIP MESSAGEs with
    `Content-Type: application/im-iscomposing+xml` whenever the user types.
    Without this gate they are relayed to the 2G MS as literal SMS bodies
    (observed live 2026-08-14: the raw XML landed in sms.txt)."""
    if not isinstance(req_text, str):
        return False
    # Match either CRLF or bare-LF line endings (Mizudroid/embedded clients
    # may emit bare-LF SIP).
    for line in req_text.replace("\r\n", "\n").split("\n"):
        if line.lower().startswith("content-type:") and "iscomposing" in line.lower():
            return True
    return False


class BridgeSip:
    def __init__(self):
        self.ip = self._detect_ip()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((SIP_BIND, SIP_PORT))
        self.sock.settimeout(POLL_INTERVAL)
        # Inbound 5G->2G MESSAGEs captured during a refresh/relay recv window
        # (see _recv_classified) are deferred here and relayed by the main loop
        # on the next iteration — a recv window can never silently drop an SMS.
        self.deferred = []
        self.etag = int(time.time())
        log("SIP", f"bound {SIP_BIND}:{SIP_PORT}, ip={self.ip} kamailio={KAMAILIO_HOST}:{KAMAILIO_PORT}")

    def _detect_ip(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1)
        try:
            s.connect((KAMAILIO_HOST, KAMAILIO_PORT))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"
        finally:
            s.close()

    def recv(self, timeout=None):
        try:
            self.sock.settimeout(timeout if timeout is not None else POLL_INTERVAL)
            data, _ = self.sock.recvfrom(65535)
            return data.decode("utf-8", errors="ignore")
        except socket.timeout:
            return None

    def _recv_classified(self, timeout, match_any):
        """Recv a datagram that belongs to OUR transaction.

        The single listener socket carries BOTH our REGISTER/relay responses
        AND inbound 5G->2G MESSAGEs. A plain recv during a refresh (60s
        cadence) or a relay round-trip would consume an inbound MESSAGE as a
        response and silently drop the SMS (observed live: 'no challenge:
        MESSAGE sip:...' with the 5G->2G cell failing). So: inbound MESSAGEs
        are deferred to self.deferred (the main loop relays them); only a
        datagram containing one of match_any (our Call-ID / branch) is
        returned as this transaction's response; anything else is dropped.
        """
        deadline = time.time() + timeout
        if not match_any:  # defensive: empty matcher would wait out the timeout
            return None
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            try:
                self.sock.settimeout(max(remaining, 0.05))
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                return None
            text = data.decode("utf-8", errors="ignore")
            if text.startswith("MESSAGE "):
                self.deferred.append(text)
                continue
            if any(m in text for m in match_any):
                return text
            # A response for a transaction we don't track (e.g. the other
            # AoR's refresh, or a stale retransmission) — benign, drop.


    def register(self, msisdn):
        # Fresh Call-ID + branch per attempt: Kamailio's registrar rejects a
        # re-REGISTER on an existing Call-ID whose CSeq does not exceed the
        # stored one ("invalid cseq") — reusing a fixed Call-ID across
        # refreshes would kill the 2G leg at first expiry.
        nonce_ts = int(time.time())
        contact = f"<sip:{msisdn}@{self.ip}:{SIP_PORT}>"
        via = f"SIP/2.0/UDP {self.ip}:{SIP_PORT};branch=z9hG4bK-bridge-{msisdn}-{nonce_ts}"
        call_id = f"bridge-reg-{msisdn}-{nonce_ts}@mvno"
        req = (
            f"REGISTER sip:{REALM}:{KAMAILIO_PORT} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{msisdn}@{REALM}>;tag=brid-t1\r\n"
            f"To: <sip:{msisdn}@{REALM}>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: 1 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Expires: 1800\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        # REGISTERs go out on the SHARED listener socket, not an ephemeral
        # one: Kamailio's fix_nated_contact() rewrites the Contact to the
        # REGISTER's source address and usrloc stores it — an ephemeral source
        # port made Kamailio relay 5G->2G MESSAGEs to that socket, where they
        # were eaten as REGISTER responses (observed live, e2e Cell 3 fail).
        # _recv_classified defers any inbound MESSAGE instead of dropping it.
        self.sock.sendto(req.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp1 = self._recv_classified(8, [call_id])
        nonce = parse_nonce(resp1 or "", "www-authenticate")
        if not nonce:
            if resp1 and "200 OK" in resp1:
                log("REGISTER", f"{msisdn} OK (no auth challenge)")
                _mark_registered(msisdn)
                return True
            log("REGISTER", f"{msisdn} no challenge: {resp1.split(chr(13)+chr(10))[0] if resp1 else 'no resp'}")
            return False

        uri = f"sip:{REALM}:{KAMAILIO_PORT}"
        digest = digest_response(msisdn, REALM, PASSWORD, "REGISTER", uri, nonce)
        auth = (
            f'Digest username="{msisdn}", realm="{REALM}", nonce="{nonce}", '
            f'uri="{uri}", response="{digest}"'
        )
        req2 = (
            f"REGISTER sip:{REALM}:{KAMAILIO_PORT} SIP/2.0\r\n"
            f"Via: {via.replace('-1-', '-2-')}\r\n"
            f"From: <sip:{msisdn}@{REALM}>;tag=brid-t1\r\n"
            f"To: <sip:{msisdn}@{REALM}>\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: 2 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Authorization: {auth}\r\n"
            f"Expires: 1800\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self.sock.sendto(req2.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp2 = self._recv_classified(8, [call_id])
        if resp2 and "200 OK" in resp2:
            log("REGISTER", f"{msisdn} REGISTER 200 OK")
            _mark_registered(msisdn)
            return True
        log("REGISTER", f"{msisdn} REGISTER rejected: {resp2.split(chr(13)+chr(10))[0] if resp2 else 'no resp'}")
        return False

    def send_message(self, msisdn, peer, body):
        uri = f"sip:{peer}@{REALM}:{KAMAILIO_PORT}"
        via = f"SIP/2.0/UDP {self.ip}:{SIP_PORT};branch=z9hG4bK-msg-{msisdn}-{int(time.time())}"
        via_branch = via.split("branch=")[1]  # exact branch: never matches a stale tx
        req1 = (
            f"MESSAGE {uri} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{msisdn}@{REALM}>;tag=msg-{msisdn}\r\n"
            f"To: <sip:{peer}@{REALM}>\r\n"
            f"Call-ID: brid-msg-{msisdn}-{int(time.time())}@mvno\r\n"
            f"CSeq: 1 MESSAGE\r\n"
            f"Max-Forwards: 10\r\n"
            f"Content-Type: text/plain\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
            f"{body}"
        )
        self.sock.sendto(req1.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp1 = self._recv_classified(8, [via_branch])
        if not resp1:
            log("SEND", f"{msisdn}->{peer} no response")
            return False
        if "200 OK" in resp1:
            log("SEND", f"{msisdn}->{peer} delivered")
            return True
        nonce = parse_nonce(resp1, "proxy-authenticate")
        if not nonce:
            log("SEND", f"{msisdn}->{peer} no challenge ({resp1.split(chr(13)+chr(10))[0]})")
            return False
        digest = digest_response(msisdn, REALM, PASSWORD, "MESSAGE", uri, nonce)
        auth = (
            f'Digest username="{msisdn}", realm="{REALM}", nonce="{nonce}", '
            f'uri="{uri}", response="{digest}"'
        )
        req2 = (
            f"MESSAGE {uri} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{msisdn}@{REALM}>;tag=msg-{msisdn}\r\n"
            f"To: <sip:{peer}@{REALM}>\r\n"
            f"Call-ID: brid-msg-{msisdn}-{int(time.time())}@mvno\r\n"
            f"CSeq: 2 MESSAGE\r\n"
            f"Max-Forwards: 10\r\n"
            f"Authorization: {auth}\r\n"
            f"Content-Type: text/plain\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
            f"{body}"
        )
        self.sock.sendto(req2.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp2 = self._recv_classified(8, [via_branch])
        ok = bool(resp2 and "200 OK" in resp2)
        log("SEND", f"{msisdn}->{peer} {'OK' if ok else 'FAIL: ' + (resp2.split(chr(13)+chr(10))[0] if resp2 else 'no resp')}")
        return ok


# -----------------------------------------------------------------------------
# Main gateway loop — interleaved 2G->5G poll + 5G->2G relay
# -----------------------------------------------------------------------------
class Gateway:
    def __init__(self):
        self.sip = BridgeSip()
        self.sc = connect(SMSC_DB)

    def handle_inbound(self, data):
        """Relay an inbound 5G->2G SIP MESSAGE (to a registered 2G AoR) into
        OsmoSMSC via SMPP and reply 200 to Kamailio so the sender sees
        delivery. Called for every MESSAGE — whether it arrived on the main
        listener recv or was deferred during a refresh/relay recv window."""
        if not data or not data.startswith("MESSAGE "):
            return
        sender, recipient, body = parse_sip_message(data)
        if recipient in MSISDN_2G:
            if is_typing_indicator(data):
                # RFC 3994 typing indicator — not an SMS; ack Kamailio (so the
                # sender's delivery state stays clean) but do NOT relay to 2G.
                log("SKIP", f"5G->2G typing indicator {sender}->{recipient} (is-composing)")
                reply_ok(data, self.sip.sock, KAMAILIO_HOST, KAMAILIO_PORT)
                return
            log("RELAY", f"5G->2G {sender}->{recipient} body='{body[:80]}'")
            reply_ok(data, self.sip.sock, KAMAILIO_HOST, KAMAILIO_PORT)
            incr("mvno_bridge_sms_attempts_total")
            try:
                smpp_submit_sm(SMPP_HOST, SMPP_PORT, sender, recipient, body)
                incr("mvno_bridge_sms_5g_to_2g_total")
            except (OSError, RuntimeError) as e:
                incr("mvno_bridge_sms_failures_total")
                log("SMPP_ERR", str(e))

    def run(self):
        log("BOOT", f"SMPP={SMPP_HOST}:{SMPP_PORT} poll={POLL_INTERVAL}s 2G={sorted(MSISDN_2G)} 5G={sorted(MSISDN_5G)}")
        for msisdn in sorted(MSISDN_2G):
            self.sip.register(msisdn)
        last_reg = time.time()
        reg_ok = True

        while True:
            # 5G->2G leg: keep the bridge's 2G-MSISDN registrations live
            # (Expires: 1800). Refresh every REGISTER_REFRESH (default 60s —
            # ~1 min is the bounded silent window after a usrloc wipe; see the
            # REGISTER_REFRESH note). If a refresh fails (e.g. lost
            # challenge/response on the shared UDP socket) retry after 30 s
            # instead of waiting a full interval, so the 2G leg cannot stay
            # dead for extended periods.
            if time.time() - last_reg > (REGISTER_REFRESH if reg_ok else 30):
                reg_ok = True
                for msisdn in sorted(MSISDN_2G):
                    if not self.sip.register(msisdn):
                        reg_ok = False
                last_reg = time.time()
            # Drain MESSAGEs deferred during the refresh's recv windows — a
            # refresh must never eat an inbound 5G->2G SMS.
            while self.sip.deferred:
                self.handle_inbound(self.sip.deferred.pop(0))

            # 2G->5G leg: drain store-and-forward queue
            try:
                rows = fetch_pending_2g_to_5g(self.sc)
            except sqlite3.Error as e:
                log("DB_ERR", f"smsc.db query failed: {e}")
                rows = []
            for row in rows:
                src = row["src_addr"]
                dest = row["dest_addr"]
                body = row["text"] or ""
                if not body and row["user_data"]:
                    # user_data is GSM 03.38 7-bit packed septets (default
                    # alphabet, data_coding_scheme 0x00). The SMSC row carries
                    # no explicit UDL column, so the true septet count is
                    # derived from the packed octet length: ceil(7*S/8) fields
                    # S into O octets, hence S == (8*O - 1)//7 where the final
                    # partial octet's zero-padding is dropped. Without
                    # n_septets the ≡7 (mod 8) boundary case emitted a
                    # spurious trailing '@' (zero-padding read as a real
                    # septet) — fixed by threading the exact UDL.
                    udl = (8 * len(row["user_data"]) - 1) // 7
                    body = gsm7_decode(bytes(row["user_data"]), n_septets=udl)
                log("POLL", f"row_id={row['id']} {src}->{dest} body='{body[:80]}'")
                incr("mvno_bridge_sms_attempts_total")
                if self.sip.send_message(src, dest, body):
                    mark_delivered(self.sc, row["id"])
                    incr("mvno_bridge_sms_2g_to_5g_total")
                    log("DELIVERED", f"row_id={row['id']} marked sent")
                else:
                    # Delivery failed (e.g. 404 — 5G dest not registered, or 429 flood).
                    # Count the attempt so the row eventually drops out of the pending
                    # set after MAX_ATTEMPTS instead of retrying at full speed forever
                    # (this also prevents a tight 0.2s retry loop from tripping pike).
                    mark_attempt(self.sc, row["id"])
                    incr("mvno_bridge_sms_failures_total")
                    log("RETRY", f"row_id={row['id']} attempt counted, will retry next poll")

            # Serve SIP listener (5G->2G inbound MESSAGEs from Kamailio relay).
            # Keep the listener on the full POLL_INTERVAL regardless of pending rows so
            # a failing 2G->5G delivery is not re-attempted in a tight 0.2s spin (which
            # trips Kamailio's pike anti-flood → 429). Backoff is handled via MAX_ATTEMPTS.
            data = self.sip.recv(timeout=POLL_INTERVAL)
            if data:
                self.handle_inbound(data)


def main():
    start_metrics_server()
    gw = Gateway()
    gw.run()


if __name__ == "__main__":
    main()
