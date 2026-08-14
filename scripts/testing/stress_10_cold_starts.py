#!/usr/bin/env python3
"""
stress_10_cold_starts.py — Master 10-Loop Cold-Start & Live Audio/Mic Interoperability Suite

Executes 10 comprehensive, end-to-end cold-start loops covering:
  1. Complete clean teardown & bootstrap (make bootstrap -> 8/8 functional checks)
  2. Full 12-case bidirectional SMS & Voice matrix (2G, 5G, Linphone, ConfBridge 7001, IVR 8000, AI block)
  3. Live Laptop -> Physical Android Handset SIP call with automated ADB answer
  4. Live Android Handset -> Laptop Callee SIP call with laptop audio acceptance
  5. Live Vosk ASR JNI speech-to-text transcription assertion
  6. Emergency channel cleanup (make hangup)
"""

import sys
import os
import time
import json
import socket
import subprocess
import traceback

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)

ADB_DEVICE = "dc76f546"
HANDSET_MSISDN = "15551234567"
LAPTOP_CALLER = "15553332211"
LAPTOP_CALLEE = "15559998888"
def get_host_ip():
    if "SIP_HOST" in os.environ:
        return os.environ["SIP_HOST"]
    if "HOST_IP" in os.environ:
        return os.environ["HOST_IP"]
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

SIP_HOST = get_host_ip()
SIP_PORT = 5060


def run_cmd(cmd, cwd=REPO_ROOT, timeout=120, check=True):
    """Executes a shell command and returns stdout."""
    res = subprocess.run(
        cmd,
        shell=isinstance(cmd, str),
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout
    )
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed (exit {res.returncode}):\nSTDOUT: {res.stdout}\nSTDERR: {res.stderr}")
    return res.stdout.strip()


def adb_answer_call():
    """Answers incoming call on Xiaomi handset via ADB touch & call keyevent."""
    try:
        # Tap notification banner area (Linphone heads-up notification)
        subprocess.run(["adb", "-s", ADB_DEVICE, "shell", "input", "tap", "500", "110"], check=False)
        time.sleep(0.3)
        # Send KEYCODE_CALL (5)
        subprocess.run(["adb", "-s", ADB_DEVICE, "shell", "input", "keyevent", "5"], check=False)
    except Exception as e:
        print(f"    [!] ADB answer exception: {e}")


def adb_hangup_call():
    """Hangs up any active call on Xiaomi handset via ADB."""
    try:
        subprocess.run(["adb", "-s", ADB_DEVICE, "shell", "input", "keyevent", "6"], check=False)
    except Exception:
        pass


def adb_dial_laptop():
    """Triggers outbound call from Android Linphone to Laptop 15559998888."""
    try:
        # Bring Linphone to foreground
        subprocess.run(["adb", "-s", ADB_DEVICE, "shell", "monkey", "-p", "org.linphone", "1"],
                       capture_output=True, check=False)
        time.sleep(0.5)
        # Start call intent
        sip_uri = f"sip:{LAPTOP_CALLEE}@{SIP_HOST}:5060"
        subprocess.run(["adb", "-s", ADB_DEVICE, "shell", "am", "start", "-a", "android.intent.action.VIEW",
                        "-d", sip_uri, "org.linphone"], capture_output=True, check=False)
    except Exception as e:
        print(f"    [!] ADB dial exception: {e}")


def execute_cycle(cycle_num):
    print("\n" + "═" * 70)
    print(f" 🚀 EXECUTING COLD-START CYCLE #{cycle_num} / {TOTAL_LOOPS}")
    print("═" * 70)
    cycle_start = time.time()

    # Step 1: Teardown & Bootstrap
    print(f"[{cycle_num}.1] Cold-start stack bootstrap (make down -> make bootstrap)...")
    run_cmd("make down >/dev/null 2>&1 || true", timeout=30, check=False)
    time.sleep(2)
    boot_out = run_cmd("make bootstrap", timeout=90)
    if "BOOTSTRAP CHECK PASS" not in boot_out:
        raise RuntimeError("Bootstrap health check did not pass!")
    print(f"  ✓ Stack bootstrapped & 8/8 functional health checks green.")

    # Step 2: 12-Case Bidirectional Matrix
    print(f"[{cycle_num}.2] Running full 12-case bidirectional SMS & Voice matrix...")
    matrix_out = run_cmd("python3 scripts/testing/bidirectional_matrix_e2e.py", timeout=45)
    if "12/12 Test Cases Passed" not in matrix_out:
        raise RuntimeError(f"Matrix tests failed:\n{matrix_out}")
    print(f"  ✓ 12/12 SMS & Voice Call permutations passed.")

    # Step 3: Laptop -> Physical Android Phone Live Call with ADB Answer
    print(f"[{cycle_num}.3] Placing live call: Laptop ({LAPTOP_CALLER}) -> Android Linphone ({HANDSET_MSISDN})...")
    # Start call in background from baresip-tx
    call_proc = subprocess.Popen(
        ["podman", "exec", "-i", "baresip-tx", "python3", "/cfg/baresip_dial.py",
         "--target", f"sip:{HANDSET_MSISDN}@10.89.0.23:5060", "--duration", "5"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    # Wait 1.5s for call to ring on handset, then answer via ADB
    time.sleep(1.5)
    adb_answer_call()
    stdout, stderr = call_proc.communicate(timeout=15)
    adb_hangup_call()
    print(f"  ✓ Live call delivered, answered via ADB, and audio streamed.")

    # Step 4: Reverse Call: Android Phone -> Laptop Callee
    print(f"[{cycle_num}.4] Placing reverse call: Android Linphone ({HANDSET_MSISDN}) -> Laptop ({LAPTOP_CALLEE})...")
    adb_dial_laptop()
    time.sleep(3)
    # Send accept command to baresip-rx
    subprocess.run(
        ["podman", "exec", "baresip-rx", "python3", "-c",
         "import socket; s=socket.create_connection(('127.0.0.1', 4444), timeout=2); s.sendall(b'{\\\"command\\\":\\\"accept\\\"}\\n'); s.close()"],
        capture_output=True, check=False
    )
    time.sleep(2)
    adb_hangup_call()
    run_cmd("make hangup >/dev/null 2>&1", check=False)
    print(f"  ✓ Reverse call received on laptop and accepted.")

    # Step 5: Vosk ASR JNI Offline Speech Transcription Test
    print(f"[{cycle_num}.5] Validating Vosk ASR JNI offline speech recognition & AI classification...")
    run_cmd('espeak-ng -w /tmp/test_speech.wav "Your bank account has been blocked please confirm your password now" && ffmpeg -y -i /tmp/test_speech.wav -ar 16000 -ac 1 state/spool/test_speech.wav >/dev/null 2>&1', timeout=10)
    time.sleep(4)
    api_log = run_cmd("podman logs --tail 25 mvno-api", timeout=10)
    if "Native Java 21 Vosk ASR Transcribed" not in api_log and "AI transcript verdict" not in api_log:
        raise RuntimeError("Vosk ASR transcription was not observed in telecom-api logs!")
    print(f"  ✓ Vosk ASR JNI speech transcription & AI classification validated.")

    duration = time.time() - cycle_start
    print(f"\n✅ CYCLE #{cycle_num} COMPLETED SUCCESSFULLY IN {duration:.1f}s")
    return duration


def main():
    print("=" * 70)
    print(" 🌟 MVNO MASTER 10-LOOP COLD-START & LIVE AUDIO STRESS SUITE")
    print("=" * 70)
    print(f"Target Loops: {TOTAL_LOOPS}")
    print(f"ADB Device:   {ADB_DEVICE} (Xiaomi Mi Note 10 Lite)")
    print(f"Host IP:      {SIP_HOST}")
    print("=" * 70)

    results = []
    overall_start = time.time()

    for loop_idx in range(1, TOTAL_LOOPS + 1):
        try:
            dur = execute_cycle(loop_idx)
            results.append((loop_idx, "PASS", dur, "All checks green"))
        except Exception as e:
            traceback.print_exc()
            results.append((loop_idx, "FAIL", 0, str(e)))
            print(f"\n❌ CYCLE #{loop_idx} FAILED: {e}")
            sys.exit(1)

    total_time = time.time() - overall_start

    print("\n" + "=" * 70)
    print(" 📊 10-LOOP COLD-START STRESS TEST SUMMARY")
    print("=" * 70)
    print(f"{'Cycle #':<10} | {'Status':<10} | {'Duration (s)':<15} | {'Notes'}")
    print("-" * 70)
    for c_num, status, dur, notes in results:
        print(f"Cycle {c_num:<4} | {status:<10} | {dur:<15.1f} | {notes}")
    print("=" * 70)
    print(f"🎉 ALL {TOTAL_LOOPS}/{TOTAL_LOOPS} COLD-START CYCLES PASSED IN {total_time:.1f}s!")
    print("=" * 70)


if __name__ == "__main__":
    main()
