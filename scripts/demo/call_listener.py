#!/usr/bin/env python3
"""
call_listener.py — Interactive Incoming Call Notification & Acceptance Utility (GUI & Terminal)

Listens for incoming SIP calls from physical handsets (e.g. Android Linphone) or UEs to the laptop.
Provides:
  1. 🔔 Desktop System Notification (notify-send)
  2. 🪟 Interactive GUI Popup (Tkinter modal with Accept & Decline buttons)
  3. 💻 Terminal Interactive Controls (Press [ENTER]/[a] to Accept, [d] to Decline)
  4. 🔌 Direct Baresip & Asterisk Integration via TCP control socket (port 4444)

Usage:
  python3 scripts/demo/call_listener.py               # GUI Popup + Terminal interactive
  python3 scripts/demo/call_listener.py --no-gui      # Terminal interactive only (ideal for tmux)
  python3 scripts/demo/call_listener.py --auto-answer # Automatically answer after 1 ring
"""

import sys
import os
import time
import socket
import json
import threading
import subprocess
import argparse

try:
    import tkinter as tk
    from tkinter import ttk
    TK_AVAILABLE = True
except ImportError:
    TK_AVAILABLE = False


class CallListener:
    def __init__(self, target_container="baresip-rx", ctrl_port=4444, no_gui=False, auto_answer=False):
        self.target_container = target_container
        self.ctrl_port = ctrl_port
        self.no_gui = no_gui or (not TK_AVAILABLE) or (not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"))
        self.auto_answer = auto_answer
        self.running = True
        self.active_call = None
        self.gui_root = None

    def send_ctrl_cmd(self, cmd_dict):
        """Send JSON command to Baresip ctrl_tcp socket inside container."""
        try:
            cmd_str = json.dumps(cmd_dict) + "\n"
            # Execute inside container directly to reach localhost:4444
            res = subprocess.run(
                ["podman", "exec", "-i", self.target_container, "nc", "-w", "2", "127.0.0.1", str(self.ctrl_port)],
                input=cmd_str.encode("utf-8"),
                capture_output=True,
                timeout=3
            )
            return res.stdout.decode("utf-8", errors="ignore")
        except Exception as e:
            print(f"[-] Error sending control command: {e}")
            return None

    def accept_call(self):
        """Accept the currently ringing call."""
        print("\n\033[1;32m[✓] ACCEPTING INCOMING CALL... Audio routed to laptop mic & speakers!\033[0m")
        # Send baresip accept command
        self.send_ctrl_cmd({"command": "accept"})
        # Also try stdio / netstring format
        subprocess.run(
            ["podman", "exec", self.target_container, "python3", "-c",
             "import socket; s=socket.create_connection(('127.0.0.1', 4444), timeout=2); s.sendall(b'{\\\"command\\\":\\\"accept\\\"}\\n'); s.close()"],
            capture_output=True
        )
        if self.gui_root:
            try:
                self.gui_root.destroy()
            except Exception:
                pass
            self.gui_root = None

    def decline_call(self):
        """Decline/hangup the incoming call."""
        print("\n\033[1;31m[✗] DECLINING / HANGING UP CALL.\033[0m")
        self.send_ctrl_cmd({"command": "hangup"})
        subprocess.run(
            ["podman", "exec", self.target_container, "python3", "-c",
             "import socket; s=socket.create_connection(('127.0.0.1', 4444), timeout=2); s.sendall(b'{\\\"command\\\":\\\"hangup\\\"}\\n'); s.close()"],
            capture_output=True
        )
        if self.gui_root:
            try:
                self.gui_root.destroy()
            except Exception:
                pass
            self.gui_root = None

    def notify_desktop(self, caller, callee):
        """Send desktop notification via libnotify notify-send."""
        try:
            subprocess.run([
                "notify-send",
                "📞 Incoming MVNO Call",
                f"From: {caller}\nTo: {callee}\nClick to answer on Laptop",
                "-u", "critical",
                "-t", "10000",
                "-a", "MVNO Telecom Core"
            ], check=False)
        except Exception:
            pass

    def show_gui_popup(self, caller, callee):
        """Display Tkinter modal dialog on the laptop desktop."""
        if self.no_gui:
            return

        def run_gui():
            root = tk.Tk()
            self.gui_root = root
            root.title("📞 Incoming MVNO Call")
            root.geometry("420x240")
            root.resizable(False, False)
            root.attributes('-topmost', True)

            # Modern Dark/High-Contrast Styling
            root.configure(bg="#1e1e2e")

            header_label = tk.Label(
                root, text="📞 INCOMING VOICE CALL",
                font=("Helvetica", 14, "bold"),
                fg="#a6e3a1", bg="#1e1e2e", pady=10
            )
            header_label.pack()

            caller_label = tk.Label(
                root, text=f"From: {caller}",
                font=("Helvetica", 12, "bold"),
                fg="#cdd6f4", bg="#1e1e2e"
            )
            caller_label.pack(pady=4)

            callee_label = tk.Label(
                root, text=f"Target: {callee} (Laptop Softphone)",
                font=("Helvetica", 10),
                fg="#bac2de", bg="#1e1e2e"
            )
            callee_label.pack(pady=2)

            btn_frame = tk.Frame(root, bg="#1e1e2e")
            btn_frame.pack(pady=20)

            accept_btn = tk.Button(
                btn_frame, text="🟢 Accept (Enter)",
                font=("Helvetica", 11, "bold"),
                bg="#2e7d32", fg="white", activebackground="#1b5e20",
                padx=15, pady=8, relief="flat", cursor="hand2",
                command=self.accept_call
            )
            accept_btn.grid(row=0, column=0, padx=10)

            decline_btn = tk.Button(
                btn_frame, text="🔴 Decline (Esc)",
                font=("Helvetica", 11, "bold"),
                bg="#c62828", fg="white", activebackground="#8e0000",
                padx=15, pady=8, relief="flat", cursor="hand2",
                command=self.decline_call
            )
            decline_btn.grid(row=0, column=1, padx=10)

            root.bind('<Return>', lambda e: self.accept_call())
            root.bind('<a>', lambda e: self.accept_call())
            root.bind('<Escape>', lambda e: self.decline_call())
            root.bind('<d>', lambda e: self.decline_call())

            root.mainloop()

        gui_thread = threading.Thread(target=run_gui, daemon=True)
        gui_thread.start()

    def handle_incoming_call(self, caller, callee):
        """Triggered when an incoming call event is detected."""
        print("\n" + "═"*65)
        print(f"\033[1;33m🔔 INCOMING CALL DETECTED!\033[0m")
        print(f"   \033[1;36mCaller:\033[0m {caller} (Android Handset / Remote UA)")
        print(f"   \033[1;36mTarget:\033[0m {callee} (Laptop Softphone)")
        print("═"*65)
        print("\033[1;32m👉 Press [ENTER] or 'a' to ACCEPT | Press 'd' or 'h' to DECLINE\033[0m")

        self.notify_desktop(caller, callee)

        if self.auto_answer:
            print("\033[0;32m[Auto-Answer Mode] Answering call in 1s...\033[0m")
            time.sleep(1)
            self.accept_call()
            return

        if not self.no_gui:
            self.show_gui_popup(caller, callee)

    def listen_terminal_input(self):
        """Reads keyboard strokes in terminal to allow terminal-based accept/decline."""
        while self.running:
            try:
                line = sys.stdin.readline()
                if not line:
                    break
                cmd = line.strip().lower()
                if cmd in ["a", "accept", "yes", "y", ""]:
                    self.accept_call()
                elif cmd in ["d", "decline", "h", "hangup", "n", "no"]:
                    self.decline_call()
            except Exception:
                break

    def monitor_logs(self):
        """Tail Kamailio and Baresip container logs for incoming call INVITEs."""
        print("\033[0;36m[*] Listening for incoming SIP calls on Kamailio :5060 and Baresip :4444...\033[0m")
        print("\033[0;37m    (Ready to receive calls from Linphone 15551234567, 2G MS, or any UE)\033[0m\n")

        # Monitor kamailio / telecom-api / baresip logs
        proc = subprocess.Popen(
            ["podman", "logs", "-f", "--tail", "0", "mvno-kamailio"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )

        last_call_time = 0
        for line in proc.stdout:
            # Detect SIP INVITE routing
            if "INVITE" in line or "ACC: call answered" in line or "INTERCEPT" in line:
                if "INVITE" in line and (time.time() - last_call_time > 3):
                    last_call_time = time.time()
                    caller = "15551234567 (Android Linphone)"
                    callee = "15559998888"
                    # Extract numbers if present in line
                    if "1555" in line:
                        parts = [w for w in line.replace(";", " ").replace("<", " ").replace(">", " ").split() if "1555" in w or "@" in w]
                        if len(parts) >= 2:
                            caller = parts[0]
                            callee = parts[1]
                    self.handle_incoming_call(caller, callee)


def main():
    parser = argparse.ArgumentParser(description="MVNO Incoming Call Listener & Notification GUI")
    parser.add_argument("--no-gui", action="store_true", help="Disable GUI popup, use terminal only")
    parser.add_argument("--auto-answer", action="store_true", help="Automatically accept calls without prompting")
    args = parser.parse_args()

    listener = CallListener(no_gui=args.no_gui, auto_answer=args.auto_answer)

    input_thread = threading.Thread(target=listener.listen_terminal_input, daemon=True)
    input_thread.start()

    try:
        listener.monitor_logs()
    except KeyboardInterrupt:
        print("\n[*] Exiting call listener.")


if __name__ == "__main__":
    main()
