#!/usr/bin/env python3
"""baresip_dial.py — dial via ctrl_tcp and wait for CALL_ESTABLISHED.

baresip's ctrl_tcp (v4.10) streams events in real-time, but piping
`timeout N cat <&3` into grep loses them: podman exec feeds the host pipe in
chunks and grep only sees data when the connection is torn down, so a call
that establishes in 0.5s appears to take the full timeout. This helper speaks
the netstring framing directly (N:payload,) and returns as soon as
CALL_ESTABLISHED is observed.

Usage:
  baresip_dial.py [--host H] [--port P] [--timeout S] [--uri sip:...] [--hangup]

Prints each event type to stderr with an elapsed timestamp; exits 0 on
CALL_ESTABLISHED (or on hangup success), 1 on timeout/failure.
"""

import argparse
import socket
import sys
import time


def send(sock, msg):
    sock.sendall(("%d:%s," % (len(msg), msg)).encode())


def parse(buf):
    """Split a netstring stream into (payloads, remaining buffer)."""
    events = []
    while True:
        colon = buf.find(b":")
        if colon < 0:
            break
        try:
            n = int(buf[:colon])
        except ValueError:
            buf = buf[1:]
            continue
        if len(buf) < colon + 1 + n + 1:
            break
        payload = buf[colon + 1:colon + 1 + n]
        rest = buf[colon + 1 + n:]
        if rest.startswith(b","):
            rest = rest[1:]
        events.append(payload)
        buf = rest
    return events, buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4444)
    ap.add_argument("--timeout", type=float, default=12.0)
    ap.add_argument("--uri", default="sip:15559998888@10.89.0.23:5060")
    ap.add_argument("--hangup", action="store_true")
    ap.add_argument("--drain", type=float, default=0.5,
                    help="seconds to drain the socket before dialing")
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(0.2)
    t0 = time.time()

    # Clear any lingering call so answermode=auto can answer the new INVITE.
    try:
        send(sock, '{"command":"hangup"}')
    except Exception:
        pass

    buf = b""
    end = time.time() + args.drain
    while time.time() < end:
        try:
            data = sock.recv(65536)
            if not data:
                break
            buf += data
        except socket.timeout:
            pass
    _, buf = parse(buf)

    if args.hangup:
        # hangup already sent above; drain briefly and report success
        end = time.time() + 1.0
        while time.time() < end:
            try:
                data = sock.recv(65536)
                if not data:
                    break
                buf += data
            except socket.timeout:
                pass
        print("hangup ok", file=sys.stderr)
        sock.close()
        return 0

    send(sock, '{"command":"dial","params":"%s"}' % args.uri)

    established = False
    end = time.time() + args.timeout
    while time.time() < end:
        try:
            data = sock.recv(65536)
            if not data:
                break
            buf += data
        except socket.timeout:
            continue
        events, buf = parse(buf)
        for evt in events:
            try:
                text = evt.decode(errors="replace")
            except Exception:
                continue
            el = time.time() - t0
            if '"type"' in text:
                # print the type field for visibility
                for part in text.split(","):
                    if '"type"' in part:
                        print("%6.2fs %s" % (el, part.strip()[:60]),
                              file=sys.stderr)
            if '"type":"CALL_ESTABLISHED"' in text:
                established = True
                break  # call is up — no need to keep reading RTCP events
        if established:
            break

    sock.close()
    if established:
        return 0
    print("timeout: CALL_ESTABLISHED not observed within %.0fs"
          % args.timeout, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
