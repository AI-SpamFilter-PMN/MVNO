#!/usr/bin/env python3
"""A/B test: SMPP SUBMIT_SM with packed GSM-7 vs unpacked ASCII (data_coding=0)."""
import socket, struct, sys, time

sys.path.insert(0, '/scripts')
from ip_sm_gw import gsm7_encode

def smpp_submit(host, port, sender, recipient, message, mode):
    s = socket.socket()
    s.settimeout(5)
    s.connect((host, port))
    bind_body = (
        b'smsclient\x00'   # system_id
        b'password\x00'    # password
        b'\x00'            # system_type
        b'\x34'            # interface_version (SMPP 3.4)
        b'\x00'            # addr_ton
        b'\x00'            # addr_npi
        b'\x00'            # address_range
    )
    bind_hdr = struct.pack('>IIII', 16 + len(bind_body), 9, 0, 1)
    s.sendall(bind_hdr + bind_body)
    resp = b''
    while len(resp) < 16:
        resp += s.recv(16 - len(resp))
    status = struct.unpack('>I', resp[8:12])[0]
    if status != 0:
        s.close()
        return f'BIND FAIL 0x{status:08X}'
    if mode == 'packed':
        msg_b = gsm7_encode(message)
    elif mode == 'ascii':
        msg_b = message.encode('ascii')
    else:
        msg_b = message.encode('utf-8')
    submit_body = (
        b'\x00\x01\x01' + sender.encode() + b'\x00'
        + b'\x01\x01' + recipient.encode() + b'\x00'
        + b'\x00\x00\x00' + b'\x00' + b'\x00\x00\x00\x00'
        + bytes([len(msg_b)]) + msg_b
    )
    hdr = struct.pack('>IIII', 16 + len(submit_body), 4, 0, 2)
    s.sendall(hdr + submit_body)
    rh = b''
    while len(rh) < 16:
        rh += s.recv(16 - len(rh))
    cmd, rstatus = struct.unpack('>II', rh[4:12])
    s.close()
    return f'mode={mode:6s} len={len(msg_b):2d} status=0x{rstatus:08X}'

if __name__ == '__main__':
    for m in ('packed', 'ascii'):
        print(smpp_submit('10.89.0.49', 2775, '15559998888', '15554443322', 'HELLO 2G AB', m))
        time.sleep(1)