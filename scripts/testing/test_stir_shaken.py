#!/usr/bin/env python3
"""
STIR/SHAKEN Cryptographic PASSporT (RFC 8224 / RFC 8588) Verification Test
Validates:
1. Dynamic ES256 ECDSA P-256 Signature Generation
2. Mandatory RFC 8588 claims (attest="A", origid=UUID, iat, dest.tn, orig.tn)
3. Cryptographic Signature Verification Endpoint
"""
import sys
import json
import base64
import urllib.request

API_KEY = "mvno-demo-key-2026"
SIGN_URL = "http://localhost:8080/api/v1/intercept/stir-shaken/sign"
VERIFY_URL = "http://localhost:8080/api/v1/intercept/stir-shaken/verify"

def main():
    print("==========================================================================")
    print(" 🔐 TEST 3: STIR/SHAKEN ES256 PASSporT (RFC 8224 / 8588) VALIDATION")
    print("==========================================================================")
    
    payload = json.dumps({
        "orig": "15553332211",
        "dest": "15559998888",
        "attest": "A"
    }).encode("utf-8")
    
    req = urllib.request.Request(SIGN_URL, data=payload, headers={"Content-Type": "application/json", "X-API-Key": API_KEY})
    with urllib.request.urlopen(req, timeout=5) as resp:
        res = json.loads(resp.read().decode("utf-8"))
        identity = res.get("identity", "")
        print(f"[*] Generated SIP Identity Header:\n{identity}\n")
        
        # Parse JWS parts
        jws = identity.split(";")[0]
        header_b64, payload_b64, sig_b64 = jws.split(".")
        
        # Base64url decode
        def b64url_decode(s):
            padding = 4 - (len(s) % 4)
            if padding != 4:
                s += "=" * padding
            return base64.urlsafe_b64decode(s).decode("utf-8")
            
        header = json.loads(b64url_decode(header_b64))
        payload_data = json.loads(b64url_decode(payload_b64))
        
        print(f"[*] Decoded JOSE Header: {json.dumps(header, indent=2)}")
        print(f"[*] Decoded PASSporT Payload: {json.dumps(payload_data, indent=2)}")
        
        # Verify RFC 8588 mandatory claims
        assert header.get("alg") == "ES256", "Missing or invalid alg claim"
        assert header.get("ppt") == "shaken", "Missing or invalid ppt claim"
        assert payload_data.get("attest") == "A", "Missing or invalid attest claim"
        assert "origid" in payload_data and payload_data["origid"].startswith("urn:uuid:"), "Missing RFC 8588 mandatory origid claim"
        assert payload_data.get("orig", {}).get("tn") == "15553332211", "Mismatched orig tn"
        assert "15559998888" in payload_data.get("dest", {}).get("tn", []), "Mismatched dest tn"
        print("[+] RFC 8588 Claims & Structure Verified.")
        
    # Verify cryptographic signature
    v_payload = json.dumps({"identity": identity}).encode("utf-8")
    v_req = urllib.request.Request(VERIFY_URL, data=v_payload, headers={"Content-Type": "application/json", "X-API-Key": API_KEY})
    with urllib.request.urlopen(v_req, timeout=5) as resp:
        v_res = json.loads(resp.read().decode("utf-8"))
        print(f"[*] Verification Result: {json.dumps(v_res, indent=2)}")
        assert v_res.get("valid") is True, "Cryptographic verification failed"
        
    print("\n🎉 ALL STIR/SHAKEN CRYPTOGRAPHIC TESTS PASSED (3/3)!")
    sys.exit(0)

if __name__ == "__main__":
    main()
