#!/usr/bin/env python3
"""
Stateful Interactive USSD Gateway (3GPP TS 24.090) Verification Test
Validates:
1. *100# Main Menu Prompt
2. Option 1: Live Account Balance Lookup from SQLite
3. Option 2: Multi-step Voucher Recharge flow
4. Option 3: 5G Network Slicing Status
"""
import sys
import json
import urllib.request

API_KEY = "mvno-demo-key-2026"
USSD_URL = "http://localhost:8080/api/v1/intercept/ussd"

def send_ussd(msisdn, input_str):
    payload = json.dumps({"msisdn": msisdn, "input": input_str}).encode("utf-8")
    req = urllib.request.Request(USSD_URL, data=payload, headers={"Content-Type": "application/json", "X-API-Key": API_KEY})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))

def main():
    print("==========================================================================")
    print(" 📱 TEST 4: STATEFUL INTERACTIVE USSD GATEWAY (TS 24.090) VALIDATION")
    print("==========================================================================")
    
    msisdn = "15553332211"
    
    # 1. Dial *100# -> Main Menu
    print("\n[*] Step 1: Subscriber dials *100#")
    r1 = send_ussd(msisdn, "*100#")
    print(f"[*] Response:\n{r1.get('message')}\n")
    assert r1.get("continueSession") is True
    assert "1. Check Account Balance" in r1.get("message")
    
    # 2. Select Option 1 -> Check Balance
    print("[*] Step 2: Subscriber replies '1' (Check Balance)")
    r2 = send_ussd(msisdn, "1")
    print(f"[*] Response:\n{r2.get('message')}\n")
    assert r2.get("continueSession") is False
    assert "Account Balance" in r2.get("message")
    
    # 3. Dial *100# -> Select Option 2 (Recharge Voucher) -> Enter PIN
    print("[*] Step 3: Subscriber dials *100# -> Option 2 (Voucher Recharge)")
    send_ussd(msisdn, "*100#")
    r3 = send_ussd(msisdn, "2")
    print(f"[*] Response:\n{r3.get('message')}\n")
    assert r3.get("continueSession") is True
    assert "voucher PIN" in r3.get("message")
    
    print("[*] Step 4: Subscriber submits 6-digit voucher PIN '889922'")
    r4 = send_ussd(msisdn, "889922")
    print(f"[*] Response:\n{r4.get('message')}\n")
    assert r4.get("continueSession") is False
    assert "redeemed successfully" in r4.get("message")
    
    # 4. Dial *100# -> Option 3 (5G Network Slices)
    print("[*] Step 5: Subscriber dials *100# -> Option 3 (5G Network Slicing)")
    send_ussd(msisdn, "*100#")
    r5 = send_ussd(msisdn, "3")
    print(f"[*] Response:\n{r5.get('message')}\n")
    assert "SST=1 (eMBB" in r5.get("message")
    
    print("🎉 ALL STATEFUL USSD GATEWAY TESTS PASSED (5/5)!")
    sys.exit(0)

if __name__ == "__main__":
    main()
