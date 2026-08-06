#!/usr/bin/env python3
"""
SMPP 3.4 Binary SMS Submission CLI Utility

Connects to Osmocom SMSC (mvno-osmosmsc) over TCP port 2775, binds as an ESME
transceiver via BIND_TRANSCEIVER (0x00000009), and submits a binary SUBMIT_SM
(0x00000004) PDU for cellular message delivery & interception policy evaluation.

Usage:
  python3 scripts/testing/send_smpp_sms.py [--sender 15551234567] [--recipient 15557654321] [--message "Text"]
"""

import argparse
import socket
import struct
import sys

def send_smpp_sms(host, port, sender, recipient, message):
    print(f"=== SMPP 3.4 Client: Connecting to {host}:{port} ===")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((host, port))
    
    # 1. Send BIND_TRANSCEIVER PDU (command_id = 0x00000009)
    system_id = b"smsclient\x00"
    password = b"password\x00"
    system_type = b"\x00"
    interface_version = b"\x34"
    addr_ton = b"\x00"
    addr_npi = b"\x00"
    address_range = b"\x00"
    
    bind_body = system_id + password + system_type + interface_version + addr_ton + addr_npi + address_range
    bind_hdr = struct.pack(">IIII", 16 + len(bind_body), 0x00000009, 0, 1)
    s.sendall(bind_hdr + bind_body)
    
    bind_resp = s.recv(1024)
    cmd_id, status = struct.unpack(">II", bind_resp[4:12])
    if status != 0:
        print(f"[-] BIND_TRANSCEIVER failed: status=0x{status:08X}", file=sys.stderr)
        s.close()
        sys.exit(1)
    print("  ✓ SMPP BIND_TRANSCEIVER Successful (Status: 0x00000000 ESME_ROK)")

    # 2. Send SUBMIT_SM PDU (command_id = 0x00000004)
    sender_b = sender.encode('utf-8') + b'\x00'
    recipient_b = recipient.encode('utf-8') + b'\x00'
    msg_b = message.encode('utf-8')

    submit_body = (
        b'\x00' +                   # service_type
        b'\x01\x01' + sender_b +    # source_addr_ton, source_addr_npi, source_addr
        b'\x01\x01' + recipient_b + # dest_addr_ton, dest_addr_npi, destination_addr
        b'\x00\x00\x00' +           # esm_class, protocol_id, priority_flag
        b'\x00' +                   # schedule_delivery_time
        b'\x00' +                   # validity_period
        b'\x00\x00\x00\x00' +       # registered_delivery, replace_if_present, data_coding, sm_default_msg_id
        bytes([len(msg_b)]) + msg_b # sm_length + short_message payload
    )

    submit_hdr = struct.pack(">IIII", 16 + len(submit_body), 0x00000004, 0, 2)
    s.sendall(submit_hdr + submit_body)

    submit_resp = s.recv(1024)
    s.close()
    
    resp_cmd_id, resp_status = struct.unpack(">II", submit_resp[4:12])
    if resp_status != 0:
        print(f"[-] SUBMIT_SM rejected: Status=0x{resp_status:08X}", file=sys.stderr)
        sys.exit(1)
    print(f"  ✓ SUBMIT_SM Delivered: Sender={sender} -> Recipient={recipient}")
    print(f"  ✓ Response: CMD=0x{resp_cmd_id:08X}, Status=0x{resp_status:08X} (ESME_ROK / SUCCESS)")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SMPP 3.4 SMS Submission Tool")
    parser.add_argument("--host", default="localhost", help="OsmoSMSC SMPP host")
    parser.add_argument("--port", type=int, default=2775, help="OsmoSMSC SMPP port")
    parser.add_argument("--sender", default="15551234567", help="Sender MSISDN")
    parser.add_argument("--recipient", default="15557654321", help="Recipient MSISDN")
    parser.add_argument("--message", default="Hello 5G MVNO SMS over SMPP 3.4", help="SMS payload text")
    args = parser.parse_args()

    send_smpp_sms(args.host, args.port, args.sender, args.recipient, args.message)
