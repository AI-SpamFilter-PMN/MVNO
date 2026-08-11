#!/usr/bin/env python3
"""
SIP MESSAGE with Digest Auth to Kamailio (one-liner demo CLI)

The LIVE_DEMO S6c/S6d path: a raw IMS SMS-over-IP MESSAGE through Kamailio
port 5060, doing the full 3-step digest dance (challenge -> nonce -> reply)
internally so the demo line stays short:

  python3 scripts/testing/send_digest_sms.py 15553332211 15554443322 "Hello raw 5G2G"
"""

import hashlib
import os
import socket
import sys

HOST = "127.0.0.1"
PORT = 5060
PASSWORD = "testpass"
REALM = "10.89.0.23"
UA = "10.89.0.62:5070"


def digest_response(username, realm, password, method, uri, nonce):
    ha1 = hashlib.md5(f"{username}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    return hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()


def build_message(username, callee, body, call_id, auth=None, cseq=1):
    uri = f"sip:{callee}@10.89.0.23:5060"
    lines = [
        f"MESSAGE {uri} SIP/2.0",
        f"Via: SIP/2.0/UDP {UA};branch=z9hG4bK{cseq};rport",
        f"From: <sip:{username}@10.89.0.23>;tag={cseq}",
        f"To: <sip:{callee}@10.89.0.23>",
        f"Call-ID: {call_id}",
        f"CSeq: {cseq} MESSAGE",
    ]
    if auth:
        lines.append(f"Proxy-Authorization: Digest {auth}")
    lines += [
        "Content-Type: text/plain",
        f"Content-Length: {len(body.encode('utf-8'))}",
        "",
        body,
    ]
    return uri, "\r\n".join(lines) + "\r\n"


def parse_challenge(resp_text):
    for header in ("proxy-authenticate", "www-authenticate"):
        for line in resp_text.splitlines():
            if line.lower().startswith(header):
                nonce = line.split('nonce="')[1].split('"')[0]
                realm = line.split('realm="')[1].split('"')[0]
                return realm, nonce
    return None, None


def send_digest_sms(username, callee, body):
    print(f"=== IMS SMS (digest): {username} -> {callee} via Kamailio {HOST}:{PORT} ===")
    call_id = f"demo-{os.getpid()}-{os.urandom(4).hex()}@10.89.0.62"

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)

    uri, req1 = build_message(username, callee, body, call_id, cseq=1)
    s.sendto(req1.encode(), (HOST, PORT))
    resp1 = s.recv(4096).decode(errors="replace")
    status = resp1.splitlines()[0] if resp1 else ""
    if "200 OK" in status:
        print(f"  ✓ {status} (no challenge)")
        s.close()
        return
    realm, nonce = parse_challenge(resp1)
    if not nonce:
        print(f"[-] No digest challenge in response: {status}", file=sys.stderr)
        s.close()
        sys.exit(1)

    resp = digest_response(username, realm, PASSWORD, "MESSAGE", uri, nonce)
    auth = (f'username="{username}", realm="{realm}", nonce="{nonce}", '
            f'uri="{uri}", response="{resp}", algorithm=MD5')
    _, req2 = build_message(username, callee, body, call_id, auth=auth, cseq=2)
    s.sendto(req2.encode(), (HOST, PORT))
    resp2 = s.recv(4096).decode(errors="replace")
    s.close()

    status2 = resp2.splitlines()[0] if resp2 else ""
    if "200 OK" in status2:
        print(f"  ✓ {status2}")
        print(f"  → receipt in ~8 s: podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2"
              if callee.startswith("15554443322")
              else f"  → body check: podman logs baresip-rx 2>&1 | grep '{body}'")
    else:
        print(f"[-] {status2}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print('Usage: python3 scripts/testing/send_digest_sms.py SENDER CALLEE "MESSAGE"')
        sys.exit(2)
    send_digest_sms(sys.argv[1], sys.argv[2], sys.argv[3])
