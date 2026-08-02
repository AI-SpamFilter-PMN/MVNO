#!/usr/bin/env python3
"""
IMS SMS Terminal for MVNO 5G/IMS SMS-over-IP (Goal 4)

Digest-authenticated SIP MESSAGE terminal that runs inside a UERANSIM UE
container (ue-1 / ue-2) and exercises the 5G/IMS SMS twin:

  - register:   2-step digest REGISTER against Kamailio (via the 5G user plane)
  - send:       send a SIP MESSAGE to a peer MSISDN (Kamailio intercepts,
                POSTs to telecom-api /api/v1/intercept/sms, then relays)
  - recv:       listen on UDP and print incoming MESSAGEs as "<msisdn>: <body>"

Usage (inside a UE container, after `ip route replace 10.89.0.23/32 dev uesimtun0`):
  python3 ims_terminal.py --mode recv --msisdn 15557654321 --host 10.89.0.23 --port 5060
  python3 ims_terminal.py --mode send --msisdn 15551234567 --peer 15557654321 \
      --host 10.89.0.23 --port 5060 --body "Hello over IMS"
"""
import argparse
import hashlib
import re
import socket
import sys
import threading
import time


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


class ImsTerminal:
    def __init__(self, msisdn, password, host, port, bind_ip, listen_port):
        self.msisdn = msisdn
        self.password = password
        self.host = host
        self.port = port
        self.bind_ip = bind_ip
        self.listen_port = listen_port
        self.realm = "localhost"
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((self.bind_ip, self.listen_port))
        self.sock.settimeout(8)
        self.call_id = f"ims-{msisdn}-{int(time.time())}@mvno"

    def _send(self, data, timeout=8):
        self.sock.settimeout(timeout)
        self.sock.sendto(data.encode(), (self.host, self.port))

    def _recv(self, timeout=8):
        self.sock.settimeout(timeout)
        try:
            data, _ = self.sock.recvfrom(65535)
            return data.decode("utf-8", errors="ignore")
        except socket.timeout:
            return None

    def register(self):
        contact = f"<sip:{self.msisdn}@{self.bind_ip}:{self.listen_port}>"
        req1 = (
            f"REGISTER sip:localhost:{self.port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.bind_ip}:{self.listen_port};branch=z9hG4bK-ims-reg1\r\n"
            f"From: <sip:{self.msisdn}@localhost>;tag=ims-tag1\r\n"
            f"To: <sip:{self.msisdn}@localhost>\r\n"
            f"Call-ID: {self.call_id}\r\n"
            f"CSeq: 1 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Expires: 3600\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self._send(req1)
        resp1 = self._recv()
        if not resp1:
            print(f"[-] REGISTER: no response from {self.host}:{self.port}", file=sys.stderr)
            return False
        nonce = parse_nonce(resp1, "www-authenticate")
        if not nonce:
            print(f"[-] REGISTER: no nonce challenge:\n{resp1.split(chr(13)+chr(10))[0]}", file=sys.stderr)
            return False

        uri = f"sip:localhost:{self.port}"
        digest = digest_response(self.msisdn, self.realm, self.password, "REGISTER", uri, nonce)
        auth = (f'Digest username="{self.msisdn}", realm="{self.realm}", nonce="{nonce}", '
                f'uri="{uri}", response="{digest}"')
        req2 = (
            f"REGISTER sip:localhost:{self.port} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.bind_ip}:{self.listen_port};branch=z9hG4bK-ims-reg2\r\n"
            f"From: <sip:{self.msisdn}@localhost>;tag=ims-tag1\r\n"
            f"To: <sip:{self.msisdn}@localhost>\r\n"
            f"Call-ID: {self.call_id}\r\n"
            f"CSeq: 2 REGISTER\r\n"
            f"Contact: {contact}\r\n"
            f"Authorization: {auth}\r\n"
            f"Expires: 3600\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self._send(req2)
        resp2 = self._recv()
        if resp2 and "200 OK" in resp2:
            print(f"[+] IMS REGISTER 200 OK for {self.msisdn}")
            return True
        print(f"[-] IMS REGISTER rejected for {self.msisdn}: {resp2.split(chr(13)+chr(10))[0] if resp2 else 'no response'}", file=sys.stderr)
        return False

    def send_message(self, peer, body):
        uri = f"sip:{peer}@localhost:{self.port}"
        via = f"SIP/2.0/UDP {self.bind_ip}:{self.listen_port};branch=z9hG4bK-ims-msg1"
        req1 = (
            f"MESSAGE {uri} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{self.msisdn}@localhost>;tag=ims-msg-tag\r\n"
            f"To: <sip:{peer}@localhost>\r\n"
            f"Call-ID: ims-msg-{int(time.time())}@mvno\r\n"
            f"CSeq: 1 MESSAGE\r\n"
            f"Max-Forwards: 10\r\n"
            f"Content-Type: text/plain\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
            f"{body}"
        )
        self._send(req1, timeout=5)
        resp1 = self._recv(timeout=5)
        if not resp1:
            print("[-] MESSAGE: no response", file=sys.stderr)
            return False
        if "200 OK" in resp1 or "202 Accepted" in resp1:
            print(f"[+] MESSAGE delivered: {self.msisdn} -> {peer}")
            return True
        nonce = parse_nonce(resp1, "proxy-authenticate")
        if not nonce:
            print(f"[-] MESSAGE: no challenge ({resp1.split(chr(13)+chr(10))[0]}); cannot auth", file=sys.stderr)
            return False

        digest = digest_response(self.msisdn, self.realm, self.password, "MESSAGE", uri, nonce)
        auth = (f'Digest username="{self.msisdn}", realm="{self.realm}", nonce="{nonce}", '
                f'uri="{uri}", response="{digest}"')
        req2 = (
            f"MESSAGE {uri} SIP/2.0\r\n"
            f"Via: {via}\r\n"
            f"From: <sip:{self.msisdn}@localhost>;tag=ims-msg-tag\r\n"
            f"To: <sip:{peer}@localhost>\r\n"
            f"Call-ID: ims-msg-{int(time.time())}@mvno\r\n"
            f"CSeq: 2 MESSAGE\r\n"
            f"Max-Forwards: 10\r\n"
            f"Authorization: {auth}\r\n"
            f"Content-Type: text/plain\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
            f"{body}"
        )
        self._send(req2, timeout=5)
        resp2 = self._recv(timeout=8)
        if resp2 and ("200 OK" in resp2 or "202 Accepted" in resp2):
            print(f"[+] MESSAGE delivered (digest): {self.msisdn} -> {peer}")
            return True
        print(f"[-] MESSAGE not accepted: {resp2.split(chr(13)+chr(10))[0] if resp2 else 'no response'}", file=sys.stderr)
        return False

    def listen(self, duration):
        end = time.time() + duration
        while time.time() < end:
            data = self._recv(timeout=min(2, max(0.5, end - time.time())))
            if not data:
                continue
            if "MESSAGE" in data.split("\r\n")[0]:
                from_match = re.search(r'From:\s*<sip:(\d+)@', data)
                sender = from_match.group(1) if from_match else "?"
                m = re.search(r"\r\n\r\n(.*)", data, re.S)
                body = m.group(1).strip() if m else ""
                print(f"{sender}: {body}", flush=True)
                self._reply_ok(data)
                print(f"[debug] replied 200 OK to {self.host}:{self.port}", flush=True)

    def _reply_ok(self, req_data):
        lines = req_data.split("\r\n")
        first = lines[0]
        try:
            method = first.split(" ")[0]
            uri = first.split(" ")[1]
        except IndexError:
            return
        hdrs = {}
        vias = []
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                k = k.strip().lower()
                if k == "via":
                    vias.append(v.strip())
                else:
                    hdrs[k] = v.strip()
        from_hdr = hdrs.get("from", "")
        to_hdr = hdrs.get("to", "")
        call_id = hdrs.get("call-id", "")
        cseq = hdrs.get("cseq", "")
        via_block = "".join(f"Via: {v}\r\n" for v in vias)
        reply = (
            f"SIP/2.0 200 OK\r\n"
            f"{via_block}"
            f"From: {from_hdr}\r\n"
            f"To: {to_hdr}\r\n"
            f"Call-ID: {call_id}\r\n"
            f"CSeq: {cseq}\r\n"
            f"Content-Length: 0\r\n\r\n"
        )
        self.sock.sendto(reply.encode(), (self.host, self.port))


def main():
    parser = argparse.ArgumentParser(description="MVNO IMS SMS terminal (Goal 4)")
    parser.add_argument("--mode", choices=["register", "send", "recv"], required=True,
                        help="register: digest REGISTER; send: send MESSAGE; recv: listen & print")
    parser.add_argument("--msisdn", required=True, help="This terminal's MSISDN")
    parser.add_argument("--peer", default=None, help="Recipient MSISDN (send mode)")
    parser.add_argument("--body", default="Hello from MVNO IMS SMS", help="Message body (send mode)")
    parser.add_argument("--host", default="127.0.0.1", help="Kamailio target host")
    parser.add_argument("--port", type=int, default=5066, help="Kamailio target port")
    parser.add_argument("--bind-ip", default="127.0.0.1", help="Local bind IP (UE tun IP for 5G path)")
    parser.add_argument("--listen-port", type=int, default=5090, help="Local UDP listen port")
    parser.add_argument("--password", default="testpass", help="SIP digest password")
    parser.add_argument("--listen", type=int, default=15, help="recv mode listen duration (s)")
    args = parser.parse_args()

    term = ImsTerminal(args.msisdn, args.password, args.host, args.port,
                       args.bind_ip, args.listen_port)
    if not term.register():
        sys.exit(1)

    if args.mode == "send":
        if not args.peer:
            print("[-] --peer required in send mode", file=sys.stderr)
            sys.exit(1)
        if not term.send_message(args.peer, args.body):
            sys.exit(1)
    elif args.mode == "recv":
        term.listen(args.listen)


if __name__ == "__main__":
    main()
