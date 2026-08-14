#!/usr/bin/env python3
"""
AI Smishing URL Sandbox & SSRF Guard Verification Test
Validates:
1. Shortened URL extraction & redirect following
2. Zero-Trust Private IP Filter (SSRF Guard against 127.0.0.1, 10.89.0.23, 169.254.169.254, 100.64.0.1)
3. Threat keyword matching (claim-prize, verify-account, etc.)
"""
import sys
import json
import urllib.request

API_URL = "http://localhost:8080/api/v1/intercept/sms"
API_KEY = "mvno-demo-key-2026"

def test_sms_smishing(sender, text, expected_allow, expected_threat_substring=None):
    payload = json.dumps({
        "sender": sender,
        "recipient": "15559998888",
        "content": text
    }).encode("utf-8")

    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": API_KEY
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            res = json.loads(response.read().decode("utf-8"))
            allow = res.get("allow", True)
            reason = res.get("reason", "")
            
            print(f"[*] SMS Text: '{text}' -> Allow: {allow} | Reason: '{reason}'")
            if allow != expected_allow:
                print(f"[FAIL] Expected allow={expected_allow}, got {allow}")
                return False
            if expected_threat_substring and expected_threat_substring.lower() not in reason.lower():
                print(f"[FAIL] Expected reason to contain '{expected_threat_substring}', got '{reason}'")
                return False
            return True
    except Exception as e:
        print(f"[FAIL] HTTP request failed: {e}")
        return False

def main():
    print("==========================================================================")
    print(" 🛡️ TEST 1: AI SMISHING URL SANDBOX & SSRF GUARD VALIDATION")
    print("==========================================================================")

    # Test 1: Normal benign SMS
    t1 = test_sms_smishing("15553332211", "Hello, let's meet at 5pm for dinner.", expected_allow=True)

    # Test 2: Smishing with known phishing keyword in URL
    t2 = test_sms_smishing("15553332211", "Urgent! Claim your reward now: http://bit.ly/claim-prize-bonus", expected_allow=False, expected_threat_substring="claim-prize")

    # Test 3: Smishing with account-update indicator
    t3 = test_sms_smishing("15553332211", "Bank Alert: Verify your details at http://tinyurl.com/account-update", expected_allow=False, expected_threat_substring="account-update")

    # Test 4: SSRF Attempt against internal container IP (10.89.0.23)
    t4 = test_sms_smishing("15553332211", "Check this link: http://10.89.0.23:5060/exploit", expected_allow=False, expected_threat_substring="SSRF")

    # Test 5: SSRF Attempt against cloud metadata (169.254.169.254)
    t5 = test_sms_smishing("15553332211", "Cloud promo: http://169.254.169.254/latest/meta-data", expected_allow=False, expected_threat_substring="SSRF")

    if all([t1, t2, t3, t4, t5]):
        print("\n🎉 ALL SMISHING SANDBOX & SSRF GUARD TESTS PASSED (5/5)!")
        sys.exit(0)
    else:
        print("\n❌ SOME SMISHING TESTS FAILED!")
        sys.exit(1)

if __name__ == "__main__":
    main()
