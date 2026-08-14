#!/usr/bin/env bash
# ==============================================================================
# noc.sh — MVNO Live NOC Center (tmux multiterminal)
# ------------------------------------------------------------------------------
# One-command control room for the live demo rig: streaming logs, call-flow
# control, usrloc evidence, RTP/pcap monitoring, and the VM metrics grid in a
# single tmux session. Every pane is labeled; control panes accept commands
# from the operator (dial/hangup/sms/usrloc) without leaving the session.
#
# Usage:
#   bash scripts/noc.sh          # create/attach the NOC session
#   bash scripts/noc.sh kill     # destroy the session
#
# Layout (4 columns × 2 rows):
#   top row (x: 0, 60, 120, 180):
#     [KAM]  kamailio SIP log   [RTP]  rtpengine log
#     [TX]   baresip-tx (caller)[RX]   baresip-rx (callee)
#   bottom row:
#     [CTRL] call/sms commands  [USRLOC] live usrloc table
#     [PCAP] live pcap + RTP    [METRICS] vmagent targets + rtp ports
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SESSION="mvno-noc"
DB="state/kamailio/kamailio.db"

if [ "${1:-}" = "kill" ]; then
  tmux kill-session -t "$SESSION" 2>/dev/null && echo "NOC session killed" || echo "no session"
  exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "NOC already running — attaching (Ctrl-b d to detach, Ctrl-b [ to scroll)"
  exec tmux attach -t "$SESSION"
fi

# ─── Build the 8-pane grid deterministically ─────────────────────────────────
# Top row: 4 horizontal splits with -p widths (75/67/50) → columns at
# x=0,60,120,180. Then per column: select top pane, split -v -p 25 → bottom
# pane. Directional navigation (-U/-R) is used because tmux renumbers pane
# indices after every split; indices are NOT stable across splits.
tmux new-session -d -s "$SESSION" -x 240 -y 60
tmux send-keys -t "$SESSION" "echo pane-0" Enter

# Row 1: 4 columns
tmux split-window -h -t "$SESSION" -p 75
tmux send-keys -t "$SESSION" "echo pane-1" Enter
tmux split-window -h -t "$SESSION" -p 67
tmux send-keys -t "$SESSION" "echo pane-2" Enter
tmux split-window -h -t "$SESSION" -p 50
tmux send-keys -t "$SESSION" "echo pane-3" Enter

# Row 2: vertical split under each column
tmux select-pane -t "$SESSION" -L -U 2>/dev/null || true   # ensure top-left
tmux select-pane -t "$SESSION" -t 0 2>/dev/null || true
tmux split-window -v -t "$SESSION" -p 25
tmux send-keys -t "$SESSION" "echo pane-4" Enter
tmux select-pane -t "$SESSION" -U; tmux select-pane -t "$SESSION" -R
tmux split-window -v -t "$SESSION" -p 25
tmux send-keys -t "$SESSION" "echo pane-5" Enter
tmux select-pane -t "$SESSION" -U; tmux select-pane -t "$SESSION" -R
tmux split-window -v -t "$SESSION" -p 25
tmux send-keys -t "$SESSION" "echo pane-6" Enter
tmux select-pane -t "$SESSION" -U; tmux select-pane -t "$SESSION" -R
tmux split-window -v -t "$SESSION" -p 25
tmux send-keys -t "$SESSION" "echo pane-7" Enter

# ─── Send commands to panes by INDEX (deterministic after grid build) ────────
# After the 4-col + 4-vsplit sequence above, pane indices are stable and map to
# a strict grid (verified in tmux 3.7):
#   idx 0 @(0,0)    idx 1 @(0,45)     <- col A: [KAM] / [CTRL]
#   idx 2 @(60,0)   idx 3 @(60,45)    <- col B: [RTP] / [USRLOC]
#   idx 4 @(120,0)  idx 5 @(120,45)   <- col C: [TX] / [PCAP]
#   idx 6 @(180,0)  idx 7 @(180,45)   <- col D: [RX] / [METRICS]
# Pane 1 (CTRL) is left interactive (no loop); every other pane runs a monitor.

# [KAM] pane 0
tmux send-keys -t "${SESSION}:0.0" \
  "while true; do clear; echo '════ [KAM] Kamailio SIP — Ctrl-b q to stop'; podman logs --tail 30 --follow mvno-kamailio 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -iE 'REGISTER|INVITE|MESSAGE|BYE|200|407|403|ACK' | tail -12; sleep 2; done" Enter
# [RTP] pane 2
tmux send-keys -t "${SESSION}:0.2" \
  "while true; do clear; echo '════ [RTP] rtpengine'; podman logs --tail 14 mvno-rtpengine 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tail -12; sleep 3; done" Enter
# [TX] pane 4
tmux send-keys -t "${SESSION}:0.4" \
  "while true; do clear; echo '════ [TX] baresip-tx (caller)'; podman logs --tail 14 baresip-tx 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -vE '^\s*$' | tail -12; sleep 3; done" Enter
# [RX] pane 6
tmux send-keys -t "${SESSION}:0.6" \
  "while true; do clear; echo '════ [RX] baresip-rx (callee, auto-answer)'; podman logs --tail 14 baresip-rx 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -vE '^\s*$' | tail -12; sleep 3; done" Enter

# [CTRL] pane 1 — interactive control (no loop)
tmux send-keys -t "${SESSION}:0.1" \
  "clear; echo '════ [CTRL] call/sms control'; echo '  bash scripts/testing/demo_call.sh dial          — rig call tx->rx (SPEAK NOW)'; echo '  bash scripts/testing/demo-verify.sh --skip-cold-start   — headless gate'; echo '  bash scripts/testing/sms_matrix.sh       — SMS 4-cell + AI-block'; echo '  sqlite3 $DB \"SELECT username,contact FROM location;\"" Enter
# [USRLOC] pane 3 — checkpoint WAL first (kamailio writes live rows to WAL;
# a passive checkpoint merges them so the file read shows current registrations)
tmux send-keys -t "${SESSION}:0.3" \
  "while true; do clear; echo '════ [USRLOC] registered endpoints'; sqlite3 \"$DB\" 'PRAGMA wal_checkpoint(PASSIVE);' >/dev/null 2>&1; sqlite3 -header -column \"$DB\" 'SELECT username, substr(contact,1,50) AS contact FROM location ORDER BY username;' 2>/dev/null || echo 'DB not ready'; sleep 5; done" Enter
# [PCAP] pane 5
tmux send-keys -t "${SESSION}:0.5" \
  "while true; do clear; echo '════ [PCAP] newest evidence capture'; F=\$(ls -t state/spool/pcaps/*.pcap 2>/dev/null | head -1); if [ -n \"\$F\" ]; then ls -la \"\$F\" | awk '{print \$5\" bytes  \"\$9}'; tshark -r \"\$F\" -d udp.port==10000,rtp -d udp.port==10022,rtp -q -z rtp,streams 2>/dev/null | grep -E 'g711U|Lost|Pkts' | head -8; else echo 'no pcap yet — run a call'; fi; sleep 5; done" Enter
# [METRICS] pane 7
tmux send-keys -t "${SESSION}:0.7" \
  "while true; do clear; echo '════ [METRICS] vmagent + rtpengine'; curl -s 'http://localhost:8429/api/v1/targets' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(\"  \"+t[\"labels\"].get(\"job\",\"?\")+\": \"+t[\"health\"]) for t in d[\"data\"][\"activeTargets\"][:14]]' 2>/dev/null || echo 'vmagent unreachable'; echo; echo -n 'rtpengine RTP ports bound: '; podman exec mvno-rtpengine ss -lun 2>/dev/null | grep -cE ':(1[0-9]{4}|2[0-9]{4})'; sleep 8; done" Enter

# ─── Finish ───────────────────────────────────────────────────────────────────
tmux rename-window -t "$SESSION" 'MVNO-NOC'
tmux select-pane -t "$SESSION" -t 0 2>/dev/null || true
if [ ! -t 0 ]; then
  echo "NOC session '$SESSION' created (detached — 8 panes)."
  echo "  → attach:  tmux attach -t $SESSION"
  echo "  → panes:   Ctrl-b + arrows; kill pane: Ctrl-b x; scroll: Ctrl-b [; detach: Ctrl-b d"
  exit 0
fi
exec tmux attach -t "$SESSION"
