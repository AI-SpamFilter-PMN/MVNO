#!/usr/bin/env python3
"""
SIP Traffic Simulator for MVNO Interception Core
Generates real SIP REGISTER & INVITE dialogs through Kamailio & RTPEngine
"""
import hashlib
import socket
import time

import sys

def calculate_digest_response(username, realm, password, method, uri, nonce):
    ha1 = hashlib.md5(f"{username}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    return hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()

def register_subscriber(username, password, port=5066):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    
    # 1. Unauthenticated REGISTER
    call_id = f"reg-{username}-{int(time.time())}@127.0.0.1"
    req1 = (
        f"REGISTER sip:localhost:{port} SIP/2.0\r\n"
        f"Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-reg1-{username}\r\n"
        f"From: <sip:{username}@localhost>;tag=tag-{username}\r\n"
        f"To: <sip:{username}@localhost>\r\n"
        f"Call-ID: {call_id}\r\n"
        f"CSeq: 1 REGISTER\r\n"
        f"Contact: <sip:{username}@127.0.0.1:5070>\r\n"
        f"Expires: 3600\r\n"
        f"Content-Length: 0\r\n\r\n"
    )
    s.sendto(req1.encode(), ('127.0.0.1', port))
    try:
        resp1, _ = s.recvfrom(2048)
        resp1_str = resp1.decode('utf-8', errors='ignore')
    except Exception as e:
        print(f"[-] Registration failed for {username}: {e}")
        s.close()
        return False
    
    # Extract nonce
    nonce = ""
    for line in resp1_str.split('\r\n'):
        if line.lower().startswith('www-authenticate:'):
            parts = line.split('nonce="')
            if len(parts) > 1:
                nonce = parts[1].split('"')[0]
    
    if not nonce:
        print(f"[-] Registration failed for {username}: No nonce received")
        s.close()
        return False
        
    digest = calculate_digest_response(username, "localhost", password, "REGISTER", f"sip:localhost:{port}", nonce)
    
    # 2. Authenticated REGISTER
    req2 = (
        f"REGISTER sip:localhost:{port} SIP/2.0\r\n"
        f"Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-reg2-{username}\r\n"
        f"From: <sip:{username}@localhost>;tag=tag-{username}\r\n"
        f"To: <sip:{username}@localhost>\r\n"
        f"Call-ID: {call_id}\r\n"
        f"CSeq: 2 REGISTER\r\n"
        f"Contact: <sip:{username}@127.0.0.1:5070>\r\n"
        f"Authorization: Digest username=\"{username}\", realm=\"localhost\", nonce=\"{nonce}\", uri=\"sip:localhost:{port}\", response=\"{digest}\"\r\n"
        f"Expires: 3600\r\n"
        f"Content-Length: 0\r\n\r\n"
    )
    s.sendto(req2.encode(), ('127.0.0.1', port))
    try:
        resp2, _ = s.recvfrom(2048)
        resp2_str = resp2.decode('utf-8', errors='ignore')
    except Exception as e:
        print(f"[-] SIP REGISTER response error: {e}")
        s.close()
        return False
    s.close()
    
    if "200 OK" in resp2_str:
        print(f"[+] SIP REGISTER 200 OK for subscriber {username}")
        return True
    else:
        print(f"[-] SIP REGISTER rejected for {username}:\n{resp2_str}")
        return False

def send_sip_invite(caller, callee, port=5066):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    call_id = f"call-{int(time.time())}@127.0.0.1"
    
    sdp = (
        "v=0\r\n"
        "o=user1 53655765 23536879 IN IP4 127.0.0.1\r\n"
        "s=-\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        "m=audio 30002 RTP/AVP 0\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
    )
    
    invite = (
        f"INVITE sip:{callee}@localhost:{port} SIP/2.0\r\n"
        f"Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-inv-{caller}\r\n"
        f"From: <sip:{caller}@localhost>;tag=tag-inv-{caller}\r\n"
        f"To: <sip:{callee}@localhost>\r\n"
        f"Call-ID: {call_id}\r\n"
        f"CSeq: 1 INVITE\r\n"
        f"Contact: <sip:{caller}@127.0.0.1:5070>\r\n"
        f"Content-Type: application/sdp\r\n"
        f"Content-Length: {len(sdp)}\r\n\r\n"
        f"{sdp}"
    )
    
    s.sendto(invite.encode(), ('127.0.0.1', port))
    try:
        resp, _ = s.recvfrom(2048)
        resp_str = resp.decode('utf-8', errors='ignore')
        first_line = resp_str.split('\r\n')[0] if resp_str else "No Response"
        print(f"[+] SIP INVITE Response for {caller}->{callee}: {first_line}")
        s.close()
        resp_str_lower = resp_str.lower()
        if any(status in resp_str_lower for status in ["100 trying", "180 ringing", "200 ok", "403 forbidden"]):
            return True
        return False
    except Exception as e:
        print(f"[-] SIP INVITE recv error: {e}")
        s.close()
        return False

if __name__ == "__main__":
    print("=== Registering Callee 15557654321 ===")
    reg_ok = register_subscriber("15557654321", "testpass")
    time.sleep(1)
    print("=== Sending Real SIP INVITE Call ===")
    inv_ok = send_sip_invite("15551234567", "15557654321")
    if not (reg_ok and inv_ok):
        sys.exit(1)
