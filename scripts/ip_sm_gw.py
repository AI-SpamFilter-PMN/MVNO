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
    lines.append("# TYPE mvno_bridge_uptime_seconds gauge")
    lines.append(f"mvno_bridge_uptime_seconds {time.time() - _START:.3f}")
    return "\n".join(lines) + "\n"


class _MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") in ("/metrics", ""):
            body = _render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
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
        SELECT id, src_addr, dest_addr, text, user_data
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


def gsm7_decode(packed):
    """Unpack a GSM 7-bit encoded octet string into Unicode text."""
    septets = []
    val = 0
    bits = 0
    for octet in packed:
        val |= octet << bits
        bits += 8
        if bits >= 7:
            septets.append(val & 0x7F)
            val >>= 7
            bits -= 7
    if bits >= 7:
        septets.append(val & 0x7F)
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
    resp = s.recv(1024)
    cmd_id, status = struct.unpack(">II", resp[4:12])
    if status != 0 or cmd_id != 0x80000009:
        s.close()
        raise RuntimeError(f"SMPP BIND failed: status=0x{status:08X}")
    log("SMPP", "BIND_TRANSCEIVER OK")

    sender_b = sender.encode() + b"\x00"
    recipient_b = recipient.encode() + b"\x00"
    msg_b = message.encode("utf-8")
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
    resp = s.recv(1024)
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
    for line in resp_text.split("\r\n"):
        if line.lower().startswith(header.lower() + ":"):
            m = re.search(r'nonce="([^"]+)"', line)
            if m:
                return m.group(1)
    return None


def reply_ok(req_text, sock, host, port):
    lines = req_text.split("\r\n")
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


def parse_sip_message(req_text):
    from_m = re.search(r'From:\s*<sip:(\d+)@', req_text)
    to_m = re.search(r'To:\s*<sip:(\d+)@', req_text)
    body_m = re.search(r"\r\n\r\n(.*)", req_text, re.S)
    sender = from_m.group(1) if from_m else None
    recipient = to_m.group(1) if to_m else None
    body = body_m.group(1).strip() if body_m else ""
    return sender, recipient, body


class BridgeSip:
    def __init__(self):
        self.ip = self._detect_ip()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((SIP_BIND, SIP_PORT))
        self.sock.settimeout(POLL_INTERVAL)
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

    def _recv_expect_ok(self, timeout=8):
        resp = self.recv(timeout=timeout)
        return resp if resp and ("200 OK" in resp) else None

    def register(self, msisdn):
        contact = f"<sip:{msisdn}@{self.ip}:{SIP_PORT}>"
        via = f"SIP/2.0/UDP {self.ip}:{SIP_PORT};branch=z9hG4bK-bridge-{msisdn}-{self.etag}"
        req = (
            f"REGISTER sip:{REALM}:{KAMAILIO_PORT} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{msisdn}@{REALM}>;tag=brid-t1\r\n"
            f"To: <sip:{msisdn}@{REALM}>\r\n"
            f"Call-ID: bridge-reg-{msisdn}-{self.etag}@mvno\r\n"
            f"CSeq: 1 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Expires: 1800\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self.sock.sendto(req.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp1 = self.recv(timeout=8)
        nonce = parse_nonce(resp1 or "", "www-authenticate")
        if not nonce:
            if resp1 and "200 OK" in resp1:
                log("REGISTER", f"{msisdn} OK (no auth challenge)")
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
            f"Call-ID: bridge-reg-{msisdn}-{self.etag}@mvno\r\n"
            f"CSeq: 2 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Authorization: {auth}\r\n"
            f"Expires: 1800\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self.sock.sendto(req2.encode(), (KAMAILIO_HOST, KAMAILIO_PORT))
        resp2 = self.recv(timeout=8)
        if resp2 and "200 OK" in resp2:
            log("REGISTER", f"{msisdn} REGISTER 200 OK")
            return True
        log("REGISTER", f"{msisdn} REGISTER rejected: {resp2.split(chr(13)+chr(10))[0] if resp2 else 'no resp'}")
        return False

    def send_message(self, msisdn, peer, body):
        uri = f"sip:{peer}@{REALM}:{KAMAILIO_PORT}"
        via = f"SIP/2.0/UDP {self.ip}:{SIP_PORT};branch=z9hG4bK-msg-{msisdn}-{int(time.time())}"
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
        resp1 = self.recv(timeout=8)
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
        resp2 = self.recv(timeout=8)
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

    def run(self):
        log("BOOT", f"SMPP={SMPP_HOST}:{SMPP_PORT} poll={POLL_INTERVAL}s 2G={sorted(MSISDN_2G)} 5G={sorted(MSISDN_5G)}")
        for msisdn in sorted(MSISDN_2G):
            self.sip.register(msisdn)
        last_reg = time.time()
        reg_ok = True

        while True:
            # 5G->2G leg: keep the bridge's 2G-MSISDN registrations live
            # (Expires: 1800). Refresh every 15 min (2x margin); if a refresh
            # fails (e.g. lost challenge/response on the shared UDP socket)
            # retry after 30 s instead of waiting a full interval, so the 2G
            # leg cannot stay dead for extended periods.
            if time.time() - last_reg > (900 if reg_ok else 30):
                reg_ok = True
                for msisdn in sorted(MSISDN_2G):
                    if not self.sip.register(msisdn):
                        reg_ok = False
                last_reg = time.time()

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
                    body = gsm7_decode(bytes(row["user_data"]))
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
            if not data:
                continue
            if not data.startswith("MESSAGE "):
                continue
            sender, recipient, body = parse_sip_message(data)
            if recipient in MSISDN_2G:
                log("RELAY", f"5G->2G {sender}->{recipient} body='{body[:80]}'")
                reply_ok(data, self.sip.sock, KAMAILIO_HOST, KAMAILIO_PORT)
                incr("mvno_bridge_sms_attempts_total")
                try:
                    smpp_submit_sm(SMPP_HOST, SMPP_PORT, sender, recipient, body)
                    incr("mvno_bridge_sms_5g_to_2g_total")
                except (OSError, RuntimeError) as e:
                    incr("mvno_bridge_sms_failures_total")
                    log("SMPP_ERR", str(e))


def main():
    start_metrics_server()
    gw = Gateway()
    gw.run()


if __name__ == "__main__":
    main()
