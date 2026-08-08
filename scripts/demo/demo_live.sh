#!/usr/bin/env bash
# ==============================================================================
# demo_live.sh — one-shot tmux demo cockpit (LIVE_DEMO S11)
# ==============================================================================
# Opens a full multi-pane live demo cockpit in a single tmux session:
#   P0  main caller  — demo_call.sh setup + dial (SPEAK NOW = YOUR live mic)
#   P1  live_tap daemon — mid-call pcap -> 16 kHz WAV -> Vosk chunks (Tier-1)
#   P2  live capture — RTP (30000-30100) + SIP (5066) on the host loopback
#   P3  mvno-kamailio logs — REGISTER / INVITE / INTERCEPT / fail-open
#   P4  mvno-api Vosk verdicts — NativeVosk + AI transcript verdict lines
#   P5  metrics — mvno_vosk_blocked_total (+ rtpengine relay counters)
#   P6  2G MS receipts — mvno-2g-ms sms.txt tail (T-A equivalent)
#   P7  evidence — newest state/spool WAVs + archived transcripts
#
# Preflight is fail-fast on the deterministic blockers and SOFT on the mic:
#   - refuses to collide with a running live_demo.sh (re-entrancy lock)
#   - requires mvno-rtpengine + mvno-api Up; ensures spool dirs 777
#   - mic_probe.sh is a WARN-ONLY check here (no-mic -> tone caller fallback;
#     the block verdict keys off the callee/synthetic leg — see LIVE_DEMO S5)
#   - runs preflight_5g.sh --auto-recover so the 5.8/5.9/7.x UE-drop ladder
#     heals the user plane before the call (never touches make gate).
#   - clean slate (Issue 8.37): removes baresip rigs + deregisters stale AoRs
#
# Usage:
#   bash scripts/demo/demo_live.sh            # build the cockpit
#   bash scripts/demo/demo_live.sh --down     # teardown (idempotent)
#
# Teardown keeps the evidence (pcaps, live-*.wav chunks, archived transcripts)
# in state/spool/ and drains smsc.db / SIP registrations so sms_matrix and
# live_demo stay green afterward.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

SESSION=mvno-live
LIVE_DEMO_LOCK="${TMPDIR:-/tmp}/mvno-live-demo.lock"   # live_demo.sh's lock (re-entrancy)
# ONLY the AoRs this cockpit itself registers: baresip-rx (15559998888, the
# preflight UAS AOR too), baresip-tx (15553332211). The bridge-owned 2G
# registrations (15554443322 / 15557778888, held by mvno-ip-sm-gw for the
# 5G->2G relay) MUST NOT be deregistered here — removing them breaks the
# 5G->2G route until the bridge's 900s refresh (a real gate regression; see
# Issue 8.38 family).
AORS=(15559998888 15553332211)

say() { echo -e "\033[0;36m[demo-live]\033[0m $*"; }
die() { echo -e "\033[0;31m[demo-live] FATAL: $*\033[0m" >&2; exit 1; }

# ------------------------------------------------------------------------------
# down — teardown (idempotent). Kills the tmux session (which stops the daemon
# and capture), removes the baresip rigs, deregisters stale AoRs (Issue 8.37),
# and drains un-sent smsc rows (gate hygiene). Evidence stays in place.
# ------------------------------------------------------------------------------
down() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    # Stray-daemon hygiene: kills the daemon a crashed tmux left behind. Note
    # this also matches a daemon started manually outside the cockpit — accept-
    # ed lab behavior (the daemon is stateless and restarts trivially).
    pkill -f 'live_tap.sh daemon' 2>/dev/null || true
    podman rm -f baresip-rx baresip-tx 2>/dev/null || true
    for u in "${AORS[@]}"; do
        python3 scripts/testing/sip_traffic_sim.py --callee "$u" --deregister >/dev/null 2>&1 || true
    done
    sqlite3 state/kamailio/kamailio.db \
        "DELETE FROM location WHERE expires < julianday('now');" 2>/dev/null || true
    sqlite3 state/hlr/smsc.db "DELETE FROM SMS WHERE sent IS NULL;" 2>/dev/null || true
    say "cockpit torn down — evidence left in state/spool/ + state/spool/pcaps/"
    say "  (bridge-owned 2G AoRs untouched — 5G->2G route intact)"
    exit 0
}

[ "${1:-}" = "--down" ] && down

# ------------------------------------------------------------------------------
# Preflight (fail-fast on deterministic blockers)
# ------------------------------------------------------------------------------
if [ -f "${LIVE_DEMO_LOCK}" ] && kill -0 "$(cat "${LIVE_DEMO_LOCK}" 2>/dev/null)" 2>/dev/null; then
    die "live_demo.sh is active (PID $(cat "${LIVE_DEMO_LOCK}")) — refusing to collide; wait for it or kill it first"
fi
if tmux has-session -t "$SESSION" 2>/dev/null; then
    die "cockpit session '${SESSION}' already exists — run 'bash scripts/demo/demo_live.sh --down' first"
fi
command -v tmux >/dev/null 2>&1 || die "tmux is required for the cockpit"
for c in mvno-rtpengine mvno-api; do
    podman ps --format '{{.Names}}' | grep -qx "$c" || die "$c not running — run 'make up' first"
done

# Spool 777 guarantee (mirror Makefile init-db — three uids: host live_tap,
# rtpengine root, mvno-api uid 1001).
mkdir -p state/spool/archived state/spool/tmp state/spool/metadata
chmod 777 state/spool state/spool/archived state/spool/tmp state/spool/metadata 2>/dev/null || true

# Mic: SOFT check (warn-only). No mic -> demo_call.sh falls back to the tone
# caller; the callee/scam leg and the block verdict still work (LIVE_DEMO S5).
if ! bash scripts/demo/mic_probe.sh >/tmp/mvno-mic-probe.log 2>&1; then
    echo -e "\033[0;33m[demo-live] ⚠ mic probe failed (see /tmp/mvno-mic-probe.log) — [caller/you] will use the canned tone leg; the callee scam block still works\033[0m"
else
    echo -e "\033[0;32m[demo-live] ✓ mic probe passed — [caller/you] will be LIVE on your microphone\033[0m"
fi

# 5G user plane: auto-recovering probe (demo path only; make gate is untouched).
say "running preflight_5g.sh --auto-recover (5.8/5.9/7.x UE-drop ladder)..."
bash scripts/testing/preflight_5g.sh --auto-recover \
    || die "5G user plane not UP after auto-recovery — fix before the call"

# Clean slate (Issue 8.37): stale registrations mask flows.
podman rm -f baresip-rx baresip-tx 2>/dev/null || true
for u in "${AORS[@]}"; do
    python3 scripts/testing/sip_traffic_sim.py --callee "$u" --deregister >/dev/null 2>&1 || true
done

# ------------------------------------------------------------------------------
# Build the cockpit
# ------------------------------------------------------------------------------
P0="cd ${REPO_ROOT} && bash scripts/testing/demo_call.sh setup && bash scripts/testing/demo_call.sh dial; exec bash"
P1="cd ${REPO_ROOT} && bash scripts/testing/live_tap.sh daemon; exec bash"
P2="cd ${REPO_ROOT} && bash -c 'if timeout 3 tshark -i lo -f \"udp portrange 30000-30100 or port 5066\" -a duration:1 -c 1 >/dev/null 2>&1; then exec tshark -i lo -f \"udp portrange 30000-30100 or port 5066\" -d \"udp.port==30000-30100,rtp\" -Y \"sip || rtp\"; fi; echo \"[live capture unavailable (permissions?) — watching newest relay pcap]\"; while true; do NEW=\$(scripts/testing/newest.sh \"state/spool/pcaps/*.pcap\"); if [ -n \"\$NEW\" ]; then tshark -r \"\$NEW\" -d \"udp.port==30000-30100,rtp\" -Y rtp 2>/dev/null | tail -6; fi; sleep 3; done'"
P3="cd ${REPO_ROOT} && podman logs -f mvno-kamailio; exec bash"
P4="cd ${REPO_ROOT} && watch -n2 'podman logs --since 5m mvno-api 2>&1 | grep -E \"NativeVosk|AI transcript verdict\" | tail -3'"
P5="cd ${REPO_ROOT} && watch -n2 'printf \"vosk_blocked=\"; curl -s \"http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total\" | jq -r .data.result[0].value[1]; curl -s \"http://localhost:9900/metrics\" 2>/dev/null | grep -E \"^rtpengine_[a-z_]+_total\" | head -3'"
P6="cd ${REPO_ROOT} && podman exec mvno-2g-ms sh -c 'tail -n +1 -f /root/.osmocom/bb/sms.txt'; exec bash"
P7="cd ${REPO_ROOT} && watch -n2 'scripts/testing/newest.sh \"state/spool/live-*.wav\" 2>/dev/null; scripts/testing/newest.sh \"state/spool/archived/*.txt\" 2>/dev/null'"

# pane-id targeting: tmux pane ids are NOT creation-sequential across
# relaunches (ids get reused out of order once sessions are killed/recreated),
# so index/id guessing drifts. split-window -P prints the id of the pane it
# just created — deterministic, version-proof.
first_pane_id() { tmux list-panes -t "$1" -F '#{pane_id}' | head -1; }

tmux new-session -d -s "$SESSION" -x 240 -y 60
tmux rename-window -t "$SESSION:0" call
P0_PANE="$(first_pane_id "$SESSION:0")"
tmux send-keys -t "$P0_PANE" "$P0" Enter
P1_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P0_PANE" -h -p 50)"
tmux send-keys -t "$P1_PANE" "$P1" Enter
P2_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P1_PANE" -v -p 50)"
tmux send-keys -t "$P2_PANE" "$P2" Enter
tmux resize-pane -t "$P0_PANE" -x 120

tmux new-window -t "$SESSION" -n monitors
P3_PANE="$(first_pane_id "$SESSION:1")"
tmux send-keys -t "$P3_PANE" "$P3" Enter
P4_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P3_PANE" -v -p 50)"
tmux send-keys -t "$P4_PANE" "$P4" Enter
P5_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P4_PANE" -h -p 50)"
tmux send-keys -t "$P5_PANE" "$P5" Enter
P6_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P5_PANE" -v -p 50)"
tmux send-keys -t "$P6_PANE" "$P6" Enter
P7_PANE="$(tmux split-window -P -F '#{pane_id}' -t "$P3_PANE" -h -p 50)"
tmux send-keys -t "$P7_PANE" "$P7" Enter

tmux select-window -t "$SESSION:0"
tmux select-pane -t "$SESSION:0.0"

NPANES=$(tmux list-panes -s -t "$SESSION" | wc -l)
say "cockpit '${SESSION}' ready — ${NPANES} panes across 2 windows"
echo ""
echo "  Window 'call'     P0 caller (SPEAK NOW) | P1 live_tap daemon | P2 RTP/SIP capture"
echo "  Window 'monitors' P3 kamailio | P4 Vosk verdicts | P5 metrics | P6 2G receipts | P7 evidence"
echo "  Attach:   tmux attach -t ${SESSION}        (or tmux a -t ${SESSION})"
echo "  Teardown: bash scripts/demo/demo_live.sh --down"
echo ""
[ -t 1 ] && { tmux attach -t "$SESSION" || true; }
