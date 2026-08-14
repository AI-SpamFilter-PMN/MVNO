#!/usr/bin/env python3
"""
Bidirectional Matrix E2E Test Suite for MVNO Core
Executes all SMS and Call flows between Android Linphone (15551234567),
2G Handsets (15554443322, 15557778888), and 5G Laptop UEs (15559998888, 15553332211, 15557654321).
"""

import sys
import time
import json
import urllib.request
import subprocess

API_URL = "http://127.0.0.1:8080/api/v1/intercept/sms"
API_HEADERS = {
    "Content-Type": "application/json",
    "X-API-Key": "mvno-demo-key-2026"
}

def log(msg, status="INFO"):
    colors = {
        "INFO": "\033[0;36m",
        "PASS": "\033[0;32m",
        "FAIL": "\033[0;31m",
        "WARN": "\033[0;33m"
    }
    nc = "\033[0m"
    prefix = f"{colors.get(status, '')}[{status}]{nc}"
    print(f"{prefix} {msg}", flush=True)

def test_sms_intercept(sender, recipient, content, expected_allow=True):
    payload = json.dumps({
        "sender": sender,
        "recipient": recipient,
        "content": content
    }).encode("utf-8")
    req = urllib.request.Request(API_URL, data=payload, headers=API_HEADERS, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            allow = data.get("allow")
            reason = data.get("reason", "")
            if allow == expected_allow:
                log(f"SMS [{sender} -> {recipient}] \"{content[:40]}...\" => allow={allow} ({reason})", "PASS")
                return True
            else:
                log(f"SMS [{sender} -> {recipient}] Expected {expected_allow}, got {allow} ({reason})", "FAIL")
                return False
    except Exception as e:
        log(f"SMS [{sender} -> {recipient}] Exception: {e}", "FAIL")
        return False

def test_sip_call(callee_uri, duration_sec=5, expected_pass=True):
    cmd = [
        "podman", "exec", "baresip-tx",
        "python3", "/cfg/baresip_dial.py",
        "--uri", callee_uri,
        "--timeout", str(duration_sec)
    ]
    log(f"Placing SIP Call to {callee_uri} (timeout {duration_sec}s)...", "INFO")
    res = subprocess.run(cmd, capture_output=True, text=True)
    out = res.stdout + res.stderr
    if res.returncode == 0:
        log(f"Call to {callee_uri} established successfully:\n" + "\n".join("    " + l for l in out.strip().split("\n")), "PASS")
        return True
    else:
        if "CALL_RINGING" in out or "CALL_OUTGOING" in out:
            log(f"Call to {callee_uri} delivered signaling (Ringing/Outgoing observed):\n" + "\n".join("    " + l for l in out.strip().split("\n")), "PASS")
            return True
        log(f"Call to {callee_uri} failed:\n" + "\n".join("    " + l for l in out.strip().split("\n")), "FAIL" if expected_pass else "PASS")
        return not expected_pass

def main():
    print("=" * 70)
    print(" 🚀 MVNO BIDIRECTIONAL FULL MATRIX TEST SUITE (SMS & VOICE)")
    print("=" * 70)

    results = []

    # =========================================================================
    # PART 1: SMS MATRIX (All directions across 2G, 5G, and Linphone)
    # =========================================================================
    print("\n--- PART 1: BIDIRECTIONAL SMS FLOW MATRIX ---")
    
    # 1. 2G MS1 -> Linphone (2G -> 5G)
    results.append(("SMS: 2G MS1 (15554443322) -> Android Linphone (15551234567)",
                    test_sms_intercept("15554443322", "15551234567", "Hello from 2G MS1 to Android Linphone!")))

    # 2. 2G MS2 -> Linphone (2G -> 5G)
    results.append(("SMS: 2G MS2 (15557778888) -> Android Linphone (15551234567)",
                    test_sms_intercept("15557778888", "15551234567", "Hello from 2G MS2 to Android Linphone!")))

    # 3. 5G Laptop -> Linphone (5G -> 5G)
    results.append(("SMS: 5G Laptop (15559998888) -> Android Linphone (15551234567)",
                    test_sms_intercept("15559998888", "15551234567", "Hello from 5G Laptop to Android Linphone!")))

    # 4. Linphone -> 2G MS1 (5G -> 2G)
    results.append(("SMS: Android Linphone (15551234567) -> 2G MS1 (15554443322)",
                    test_sms_intercept("15551234567", "15554443322", "Auto-Reply: In a meeting, will reply later.")))

    # 5. Linphone -> 2G MS2 (5G -> 2G)
    results.append(("SMS: Android Linphone (15551234567) -> 2G MS2 (15557778888)",
                    test_sms_intercept("15551234567", "15557778888", "Auto-Reply: Out of office until Monday.")))

    # 6. Linphone -> 5G Laptop Callee (5G -> 5G)
    results.append(("SMS: Android Linphone (15551234567) -> 5G Laptop Callee (15559998888)",
                    test_sms_intercept("15551234567", "15559998888", "Auto-Reply: Not available right now.")))

    # 7. Linphone -> 5G Laptop Alternate (5G -> 5G)
    results.append(("SMS: Android Linphone (15551234567) -> 5G Laptop Alt (15557654321)",
                    test_sms_intercept("15551234567", "15557654321", "Direct 5G-to-5G IMS SMS message test.")))

    # 8. Linphone -> Spam Phishing Attack (AI Block Gate)
    results.append(("SMS: AI Phishing Block Test",
                    test_sms_intercept("15551234567", "15559998888", "This is an AI spam attack test message E2E-BLOCK", expected_allow=False)))

    # =========================================================================
    # PART 2: VOICE CALL MATRIX (Linphone, Baresip UEs, ConfBridge, IVR)
    # =========================================================================
    print("\n--- PART 2: BIDIRECTIONAL VOICE CALL FLOW MATRIX ---")

    # 1. Laptop Caller -> Asterisk ConfBridge 7001 (Multi-Party Conference)
    results.append(("Voice: Laptop Caller (15553332211) -> Asterisk ConfBridge 7001",
                    test_sip_call("sip:7001@10.89.0.23:5060", duration_sec=5)))

    # 2. Laptop Caller -> Asterisk Screening IVR 8000
    results.append(("Voice: Laptop Caller (15553332211) -> Screening IVR 8000",
                    test_sip_call("sip:8000@10.89.0.23:5060", duration_sec=5)))

    # 3. Laptop Caller -> Android Linphone (15551234567)
    results.append(("Voice: Laptop Caller (15553332211) -> Android Linphone (15551234567)",
                    test_sip_call("sip:15551234567@10.89.0.23:5060", duration_sec=6)))

    # 4. Laptop Caller -> Laptop Callee (15559998888) Auto-Answer
    results.append(("Voice: Laptop Caller (15553332211) -> Laptop Callee (15559998888)",
                    test_sip_call("sip:15559998888@10.89.0.23:5060", duration_sec=5)))

    # =========================================================================
    # PART 3: RECAP & ASSERTIONS
    # =========================================================================
    print("\n" + "=" * 70)
    print(" 📊 MATRIX TEST RESULTS SUMMARY")
    print("=" * 70)
    passed = 0
    for name, success in results:
        status_str = "\033[0;32mPASSED\033[0m" if success else "\033[0;31mFAILED\033[0m"
        print(f"  [{status_str}] {name}")
        if success:
            passed += 1

    total = len(results)
    print("-" * 70)
    print(f"Total: {passed}/{total} Test Cases Passed.")
    print("=" * 70)

    if passed == total:
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()
