#!/usr/bin/env python3
"""
call_monitor.py — Real-Time Live Call Status, RTP Stream & Mic VU-Meter HUD

Displays live terminal dashboard for active SIP calls across:
  • Kamailio Active Dialogs
  • Asterisk ConfBridge / PJSIP Channels
  • RTPEngine Kernel/Userspace Media Streams
  • Real-Time Microphone Audio VU Meter & decibel level

Usage:
  python3 scripts/demo/call_monitor.py
  make monitor
"""

import os
import sys
import time
import subprocess
import json
import re

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)


def get_active_dialogs():
    """Query Kamailio for active SIP dialogs."""
    try:
        res = subprocess.run(
            ["podman", "exec", "mvno-kamailio", "kamcmd", "dlg.list"],
            capture_output=True, text=True, timeout=2
        )
        if "callid" in res.stdout.lower() or "dialog" in res.stdout.lower():
            # Count active dialog blocks
            matches = re.findall(r"callid:\s*([^\s]+)", res.stdout, re.IGNORECASE)
            return len(matches), res.stdout.strip()
    except Exception:
        pass
    return 0, ""


def get_asterisk_channels():
    """Query Asterisk for active channels."""
    try:
        res = subprocess.run(
            ["podman", "exec", "mvno-asterisk", "asterisk", "-rx", "core show channels"],
            capture_output=True, text=True, timeout=2
        )
        out = res.stdout.strip()
        m = re.search(r"(\d+)\s+active channel", out)
        count = int(m.group(1)) if m else 0
        return count, out
    except Exception:
        return 0, "Asterisk offline"


def get_baresip_calls():
    """Check if baresip containers have active calls."""
    active = []
    for c in ["baresip-tx", "baresip-rx"]:
        try:
            res = subprocess.run(
                ["podman", "logs", "--tail", "15", c],
                capture_output=True, text=True, timeout=2
            )
            if "Call established" in res.stdout:
                lines = [l for l in res.stdout.splitlines() if "Call established" in l]
                if lines:
                    active.append(f"{c}: {lines[-1].strip()[-60:]}")
        except Exception:
            pass
    return active


def get_live_mic_level():
    """Sample host microphone via parec/sox for real-time VU meter."""
    try:
        res = subprocess.run(
            "timeout 0.3 parec --raw --channels=1 --rate=16000 --format=s16le 2>/dev/null | sox -t raw -r 16000 -e signed-integer -b 16 -c 1 - -n stat 2>&1",
            shell=True, capture_output=True, text=True, timeout=2
        )
        m = re.search(r"Maximum amplitude:\s+([0-9.]+)", res.stdout)
        if m:
            amp = float(m.group(1))
            return amp
    except Exception:
        pass
    return 0.0


def render_vu_bar(amp, width=28):
    """Render colored ASCII VU meter bar."""
    filled = int(min(1.0, amp * 2.5) * width)
    bar = "█" * filled + "░" * (width - filled)
    if amp > 0.35:
        color = "\033[1;32m"  # Green (Speaking)
        status = "🎙️ SPEAKING (ACTIVE)"
    elif amp > 0.08:
        color = "\033[1;33m"  # Yellow (Ambient)
        status = "🔉 AMBIENT AUDIO"
    else:
        color = "\033[1;30m"  # Gray (Silence)
        status = "🔇 SILENCE / MUTED"
    return f"{color}[{bar}]\033[0m {status} (amp={amp:.3f})"


def main():
    print("\033[2J\033[H", end="")  # Clear screen
    try:
        while True:
            dlg_count, dlg_raw = get_active_dialogs()
            ast_count, ast_raw = get_asterisk_channels()
            baresip_active = get_baresip_calls()
            mic_amp = get_live_mic_level()

            is_call_active = (dlg_count > 0) or (ast_count > 0) or (len(baresip_active) > 0)

            # Build UI Header
            output = []
            output.append("\033[H")  # Move cursor to top-left
            output.append("═" * 72)
            output.append(" 📡 MVNO LIVE CALL MONITOR & REAL-TIME AUDIO HUD")
            output.append("═" * 72)

            if is_call_active:
                output.append(f"\033[1;42;37m  ● STATUS: LIVE CALL CONNECTED & STREAMING  \033[0m")
            else:
                output.append(f"\033[1;40;37m  ○ STATUS: IDLE (WAITING FOR INCOMING / OUTGOING CALL)  \033[0m")

            output.append("-" * 72)
            output.append(f"📞 Active SIP Dialogs (Kamailio):    {dlg_count}")
            output.append(f"🎙️ Asterisk Media Channels:         {ast_count}")
            if baresip_active:
                for b in baresip_active:
                    output.append(f"  • {b}")
            else:
                output.append("  • Softphone UAs: Ready (15553332211, 15559998888)")

            output.append("-" * 72)
            output.append(f"🎤 Host Microphone VU Meter:")
            output.append(f"  {render_vu_bar(mic_amp)}")

            output.append("-" * 72)
            output.append("💡 Press Ctrl-C to exit monitor. (Run `make hangup` to drop calls)")
            output.append("═" * 72)

            sys.stdout.write("\n".join(output) + "\n")
            sys.stdout.flush()
            time.sleep(0.4)

    except KeyboardInterrupt:
        print("\nExiting Live Call Monitor.")


if __name__ == "__main__":
    main()
