#!/usr/bin/env python3
"""
Raw Binary SMPP 3.4 SMS Submission (one-liner demo CLI)

The LIVE_DEMO S6a path: BIND_TRANSCEIVER (0x00000009) + SUBMIT_SM (0x00000004)
straight over TCP to OsmoSMSC port 2775, with positional args so the demo line
stays short:

  python3 scripts/testing/send_raw_smpp.py 15557778888 15554443322 "Hello raw 2G2G"
"""

import socket
import struct
import sys

HOST = "localhost"
PORT = 2775


def smpp_pdu(command_id, seq, body):
    return struct.pack(">IIII", 16 + len(body), command_id, 0, seq) + body


def send_raw_smpp(sender, recipient, message):
    print(f"=== SMPP 3.4 raw: {sender} -> {recipient} via {HOST}:{PORT} ===")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((HOST, PORT))

    bind_body = b"smsclient\x00password\x00\x00\x34\x00\x00\x00"
    s.sendall(smpp_pdu(0x00000009, 1, bind_body))
    bind_resp = s.recv(1024)
    _, status = struct.unpack(">II", bind_resp[4:12])
    if status != 0:
        print(f"[-] BIND_TRANSCEIVER failed: status=0x{status:08X}", file=sys.stderr)
        sys.exit(1)
    print("  ✓ SMPP BIND_TRANSCEIVER Successful (Status: 0x00000000 ESME_ROK)")

    msg_b = message.encode("utf-8")
    submit_body = (
        b"\x00" + b"\x01\x01" + sender.encode("utf-8") + b"\x00"
        + b"\x01\x01" + recipient.encode("utf-8") + b"\x00"
        + b"\x00\x00\x00" + b"\x00" + b"\x00" + b"\x00\x00\x00\x00"
        + bytes([len(msg_b)]) + msg_b
    )
    s.sendall(smpp_pdu(0x00000004, 2, submit_body))
    submit_resp = s.recv(1024)
    s.close()

    resp_cmd_id, resp_status = struct.unpack(">II", submit_resp[4:12])
    if resp_status != 0:
        print(f"[-] SUBMIT_SM rejected: Status=0x{resp_status:08X}", file=sys.stderr)
        sys.exit(1)
    print(f"  ✓ SUBMIT_SM accepted: CMD=0x{resp_cmd_id:08X}, Status=0x{resp_status:08X} (ESME_ROK / SUCCESS)")
    print("  → MS1 receipt in ~8 s: podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt | tail -2")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python3 scripts/testing/send_raw_smpp.py SENDER RECIPIENT \"MESSAGE\"")
        sys.exit(2)
    send_raw_smpp(sys.argv[1], sys.argv[2], sys.argv[3])
