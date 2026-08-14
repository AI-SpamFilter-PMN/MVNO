#!/usr/bin/env bash
# ==============================================================================
# demo_live.sh — one-shot tmux demo cockpit (LIVE_DEMO S11)
# ==============================================================================
# Opens a multi-pane live demo cockpit in a tmux session with **at most 4 panes
# per window** (2x2 grid), so no screen ever shows more than 4 terminals:
#   Window 'call'      (P0 caller + speaker) | P1 live_tap daemon | P2 RTP/SIP
#                      capture | P4 Vosk verdicts + LIVE transcript text
#   Window 'monitors'  P3 kamailio logs | P5 metrics | P7 evidence | watchdog log
#   Window 'sms'       S1 SMS MO tools (send_rest_sms / send_smpp_sms / sms_matrix)
#                      | S2 smsc.db + bridge counters | S3 MT 2G handset receipts
#                      (sms.txt) | S4 MT 5G/IMS receiver (ims_rx logs)
#
#   Window switching:  Ctrl-b n / Ctrl-b p, or:
#                      tmux select-window -t mvno-live:call|monitors|sms
#
# --wireshark does NOT add a pane anymore: it launches the Wireshark GUI as a
#   DETACHED process (a GUI cannot live well inside a tmux pane), with the Qt
#   platform plugin + XAUTHORITY + lo capture-permission handled explicitly.
#   GUI errors land in state/logs/wireshark-gui.log.
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
#   bash scripts/demo/demo_live.sh             # build the cockpit (3 windows x 4 panes)
#   bash scripts/demo/demo_live.sh --wireshark # + DETACHED Wireshark GUI capture
#                                              #   (no pane slot; log: state/logs/wireshark-gui.log)
#   bash scripts/demo/demo_live.sh --windowed  # pop the cockpit up as a VISIBLE
#                                              #   desktop terminal window (needs
#                                              #   DISPLAY/WAYLAND_DISPLAY + a
#                                              #   terminal emulator; headless
#                                              #   prints the tmux attach hint)
#   bash scripts/demo/demo_live.sh --down      # teardown (idempotent)
#
# Teardown keeps the evidence (pcaps, live-*.wav chunks, archived transcripts)
# in state/spool/ and drains smsc.db / SIP registrations so sms_matrix and
# live_demo stay green afterward.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SESSION=mvno-live
LIVE_DEMO_LOCK="${TMPDIR:-/tmp}/mvno-live-demo.lock"   # live_demo.sh's lock (re-entrancy)
# ONLY the AoRs this cockpit itself registers: the baresip rigs (single source
# MVNO_BARESIP_AORS — includes the shared UAS AoR ${MVNO_UAS_AOR}). The
# bridge-owned 2G registrations (${MVNO_MSISDN_2G[*]}, held by mvno-ip-sm-gw
# for the 5G->2G relay) MUST NOT be deregistered here — removing them breaks
# the 5G->2G route until the bridge's 60s refresh (a real gate regression; see
# Issue 8.38 family).
AORS=("${MVNO_BARESIP_AORS[@]}")

say() { echo -e "\033[0;36m[demo-live]\033[0m $*"; }
die() { echo -e "\033[0;31m[demo-live] FATAL: $*\033[0m" >&2; exit 1; }

# ------------------------------------------------------------------------------
# down — teardown (idempotent). Kills the tmux session (which stops the daemon
# and capture), removes the baresip rigs, deregisters stale AoRs (Issue 8.37),
# and drains un-sent smsc rows (gate hygiene). Evidence stays in place.
# ------------------------------------------------------------------------------
down() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    rm -f "${TMPDIR:-/tmp}/mvno-cockpit-panes.map"
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

# Opt-in flags. --wireshark launches a DETACHED Wireshark GUI capture (no pane
# slot — a GUI cannot live reliably inside tmux); --windowed pops the
# cockpit up as a VISIBLE desktop terminal window (a terminal emulator attaches
# to the tmux session). Neither is ever part of the deterministic cockpit /
# proof harness: --wireshark requires a display + the wireshark binary;
# --windowed requires a display + an emulator, and headless runs print the
# tmux-attach hint instead.
GUI_CAP=0
WINDOWED=0
FORCE_TONE=0
for a in "$@"; do
    case "$a" in
        --wireshark) GUI_CAP=1 ;;
        --windowed)  WINDOWED=1 ;;
        --tone)      FORCE_TONE=1 ;;  # deterministic mode: never use the host mic
        --down)      down ;;   # teardown is position-independent (down exits)
        *) die "unknown flag: $a (see usage)" ;;
    esac
done
# summary suffix: shown only when the GUI will actually be launched.
GUI_SUFFIX=""
[ "${GUI_CAP}" -eq 1 ] && GUI_SUFFIX=" + Wireshark GUI (detached)"

# ------------------------------------------------------------------------------
# Preflight (fail-fast on deterministic blockers)
# ------------------------------------------------------------------------------
if [ -f "${LIVE_DEMO_LOCK}" ] && kill -0 "$(cat "${LIVE_DEMO_LOCK}" 2>/dev/null)" 2>/dev/null; then
    die "live_demo.sh is active (PID $(cat "${LIVE_DEMO_LOCK}")) — refusing to collide; wait for it or kill it first"
fi
if tmux has-session -t "$SESSION" 2>/dev/null; then
    die "cockpit session '${SESSION}' already exists — run 'bash scripts/demo/demo_live.sh --down' first"
fi
# Registry cockpit lock (single source: common.sh): a human-run cockpit holds a
# lock from launch (before the tmux session exists — its preflight window would
# otherwise be invisible to the watchdog's run_in_flight; the child
# preflight_5g.sh holds mvno-preflight.lock during the probe, this covers the
# whole launcher). Released on EXIT (incl. --down).
acquire_run_lock mvno-demo-live.lock || die "another run is in flight — wait for it or clear stale locks in ${TMPDIR:-/tmp}"
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
# --tone (deterministic/cockpit-proof mode) skips the probe entirely so the
# run never depends on the operator's mic or a Pulse first-open race.
if [ "${FORCE_TONE}" -eq 1 ]; then
    export MVNO_FORCE_TONE=1   # demo_call.sh: PULSE_OK=0 -> canned tone caller
    echo -e "\033[0;36m[demo-live] --tone: mic probe skipped — canned tone caller (deterministic)\033[0m"
elif ! bash scripts/demo/mic_probe.sh >/tmp/mvno-mic-probe.log 2>&1; then
    echo -e "\033[0;33m[demo-live] ⚠ mic probe failed (see /tmp/mvno-mic-probe.log) — [caller/you] will use the canned tone leg; the callee scam block still works\033[0m"
else
    echo -e "\033[0;32m[demo-live] ✓ mic probe passed — [caller/you] will be LIVE on your microphone\033[0m"
fi

# 5G user plane: auto-recovering probe (demo path only; make gate is untouched).
say "running preflight_5g.sh --auto-recover (5.8/5.9/7.x UE-drop ladder)..."
bash scripts/testing/preflight_5g.sh --auto-recover \
    || die "5G user plane not UP after auto-recovery — fix before the call"

# Bridge 2G-AoR assert (Issue 8.38 class): the 5G->2G SMS relay depends on the
# bridge's registrations (15554443322/15557778888) being live in usrloc. Fail
# fast with the fix message instead of a confusing 404 mid-demo. Single source
# of truth for the AoR list lives in scripts/mvno-stack-watchdog.sh --check-bridge.
say "asserting bridge 2G-AoR registrations (5G->2G relay path)..."
bash scripts/mvno-stack-watchdog.sh --check-bridge \
    || die "bridge 2G AoRs not registered in usrloc — restart mvno-ip-sm-gw (it re-REGISTERs at boot) or run: bash scripts/mvno-stack-watchdog.sh --once"
say "✓ bridge 2G AoRs registered — 5G->2G relay path live"

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
P2="cd ${REPO_ROOT} && bash -c 'if timeout 3 tshark -i lo -f \"udp portrange 10000-20000 or port 5060\" -a duration:1 -c 1 >/dev/null 2>&1; then exec tshark -i lo -f \"udp portrange 10000-20000 or port 5060\" -d \"udp.port==10000-20000,rtp\" -Y \"sip || rtp\"; fi; echo \"[live capture unavailable (permissions?) — watching newest relay pcap]\"; while true; do NEW=\$(scripts/testing/newest.sh \"state/spool/pcaps/*.pcap\"); if [ -n \"\$NEW\" ]; then tshark -r \"\$NEW\" -d \"udp.port==10000-20000,rtp\" -Y rtp 2>/dev/null | tail -6; fi; sleep 3; done'"
P3="cd ${REPO_ROOT} && podman logs -f mvno-kamailio; exec bash"
# P4 — live Vosk readout: verdict logs + the RAW recognized text (newest
# live-*.txt, the near-real-time transcription stream written by NativeVoskService).
P4="cd ${REPO_ROOT} && watch -n2 'podman logs --since 5m mvno-api 2>&1 | grep -E \"NativeVosk|AI transcript verdict\" | tail -3; echo; NEW=\$(scripts/testing/newest.sh \"state/spool/archived/live-*.txt\" 2>/dev/null); if [ -n \"\$NEW\" ]; then echo \"── LIVE transcript:\"; tail -c 300 \"\$NEW\" 2>/dev/null; fi'"
P5="cd ${REPO_ROOT} && watch -n2 'printf \"vosk_blocked=\"; curl -s \"http://localhost:8428/api/v1/query?query=mvno_vosk_blocked_total\" | jq -r .data.result[0].value[1]; curl -s \"http://localhost:9900/metrics\" 2>/dev/null | grep -E \"^rtpengine_[a-z_]+_total\" | head -3'"
P7="cd ${REPO_ROOT} && watch -n2 'scripts/testing/newest.sh \"state/spool/live-*.wav\" 2>/dev/null; scripts/testing/newest.sh \"state/spool/archived/*.txt\" 2>/dev/null'"
P9W="cd ${REPO_ROOT} && tail -f state/logs/watchdog.log; exec bash"
# --- Window 'sms': MO/MT terminals for 2G + 5G (at most 4 per screen) ---
# S1 (MO) — interactive sender tools; the operator fires MO here and watches MT below.
S1="cd ${REPO_ROOT} && echo '--- SMS window: MO (send) here, MT receipts below ---' && echo ' send_rest_sms.sh <sender> <recipient> <body>   # REST MO via telecom-api' && echo ' send_smpp_sms.py                            # SMPP BIND_TRANSCEIVER MO via osmo-smsc 2775' && echo ' bash scripts/testing/sms_matrix.sh           # full 5-cell runbook (MO+MT assert)' && echo ' MT: S3=2G handset (sms.txt)  S4=5G/IMS receiver  S2=counters' && exec bash"
# S2 — smsc.db + bridge counter watch (MO/MT accounting).
S2="cd ${REPO_ROOT} && watch -n3 'echo \"bridge SMS counters:\"; curl -s http://localhost:9100/metrics 2>/dev/null | grep -E \"^mvno_bridge_sms_(2g_to_5g|5g_to_2g)_total\"; echo \"smsc.db pending:\"; sqlite3 state/hlr/smsc.db \"SELECT count(*) FROM SMS WHERE sent IS NULL;\" 2>/dev/null; echo \"smsc.db total:\"; sqlite3 state/hlr/smsc.db \"SELECT count(*) FROM SMS;\" 2>/dev/null'"
# S3 — MT on 2G: the real OsmoMSC handset receipt (T-A equivalent).
S3="cd ${REPO_ROOT} && podman exec mvno-2g-ms sh -c 'tail -n +1 -f /root/.osmocom/bb/sms.txt'; exec bash"
# S4 — MT on 5G/IMS: follow any sms_matrix receiver (ims_rx54/56); instruct if none.
S4="cd ${REPO_ROOT} && bash -c 'while true; do R=\$(podman ps -a --format \"{{.Names}}\" 2>/dev/null | grep -E \"^ims_rx\" | head -1); if [ -n \"\$R\" ]; then echo \"── 5G/IMS MT receiver: \$R\"; podman logs -f --tail 20 \"\$R\" 2>/dev/null; echo \"(receiver ended — re-trying)\"; sleep 2; else echo \"no 5G/IMS receiver yet\"; echo \" run sms_matrix.sh (Cell 3/4) or: start_recv ims_rx54 15551234567 10.89.0.54 90\"; sleep 4; fi; done'"

# pane-id targeting: tmux pane ids are NOT creation-sequential across
# relaunches (ids get reused out of order once sessions are killed/recreated),
# so index/id guessing drifts. split-window -P prints the id of the pane it
# just created — deterministic, version-proof.
first_pane_id() { tmux list-panes -t "$1" -F '#{pane_id}' | head -1; }

window_grid() {  # $1=win  $2..$5 = 4 pane commands → 2x2 grid (TL,TR,BL,BR).
    # Echoes the 4 pane IDs so callers can record a version-proof role map —
    # tmux RENUMBERS pane indexes by layout (not creation order), so index
    # guessing drifts across tmux versions; pane IDs do not.
    local win="$1" a b c d
    a="$(first_pane_id "${SESSION}:${win}")"
    tmux send-keys -t "$a" "$2" Enter
    b="$(tmux split-window -P -F '#{pane_id}' -t "$a" -h -p 50)"
    tmux send-keys -t "$b" "$3" Enter
    c="$(tmux split-window -P -F '#{pane_id}' -t "$a" -v -p 50)"
    tmux send-keys -t "$c" "$4" Enter
    d="$(tmux split-window -P -F '#{pane_id}' -t "$b" -v -p 50)"
    tmux send-keys -t "$d" "$5" Enter
    printf '%s %s %s %s\n' "$a" "$b" "$c" "$d"
}

PANEMAP="${TMPDIR:-/tmp}/mvno-cockpit-panes.map"
rm -f "$PANEMAP"

tmux new-session -d -s "$SESSION" -x 240 -y 60
tmux rename-window -t "$SESSION:0" call
read -r a b c d <<< "$(window_grid 0 "$P0" "$P1" "$P2" "$P4")"    # call:     caller | live_tap | capture | LIVE transcript+verdict
printf 'call|%s|P0\ncall|%s|P1\ncall|%s|P2\ncall|%s|P4\n' "$a" "$b" "$c" "$d" >> "$PANEMAP"

tmux new-window -t "$SESSION" -n monitors
read -r a b c d <<< "$(window_grid 1 "$P3" "$P5" "$P7" "$P9W")"   # monitors: kamailio | metrics | evidence | watchdog
printf 'monitors|%s|P3\nmonitors|%s|P5\nmonitors|%s|P7\nmonitors|%s|watchdog\n' "$a" "$b" "$c" "$d" >> "$PANEMAP"

tmux new-window -t "$SESSION" -n sms
read -r a b c d <<< "$(window_grid 2 "$S1" "$S2" "$S3" "$S4")"    # sms:      MO tools | counters | MT 2G | MT 5G/IMS
printf 'sms|%s|S1\nsms|%s|S2\nsms|%s|S3\nsms|%s|S4\n' "$a" "$b" "$c" "$d" >> "$PANEMAP"

tmux select-window -t "$SESSION:call"
tmux select-pane -t "$SESSION:call.0"

NPANES=$(tmux list-panes -s -t "$SESSION" | wc -l)
NWIN=$(tmux list-windows -t "$SESSION" | wc -l)
say "cockpit '${SESSION}' ready — ${NPANES} panes across ${NWIN} windows (max 4 visible at once)"
echo ""
echo "  'call'     P0 caller (SPEAK NOW) | P1 live_tap | P2 RTP/SIP capture | P4 Vosk LIVE transcript+verdict"
echo "  'monitors' P3 kamailio | P5 metrics | P7 evidence | watchdog log"
echo "  'sms'      S1 SMS MO tools | S2 smsc.db+bridge counters | S3 MT 2G handset | S4 MT 5G/IMS receiver${GUI_SUFFIX}"
echo "  Windows:   Ctrl-b n / Ctrl-b p (or tmux select-window -t ${SESSION}:call|monitors|sms)"
echo "  Attach:    tmux attach -t ${SESSION}        (or tmux a -t ${SESSION})"
echo "  Windowed:  bash scripts/demo/demo_live.sh --windowed   (pops up a desktop terminal)"
echo "  Teardown:  bash scripts/demo/demo_live.sh --down"
echo ""

# launch_wireshark — DETACHED Wireshark GUI (never a tmux pane: a GUI cannot
# live reliably inside tmux). Handles the three classic failure classes that
# kept the GUI from opening with the stack:
#   (1) Qt platform plugin — under Wayland prefer 'wayland' (plugin present);
#       else fall back to 'xcb' (XWayland). A bare `wireshark` with a stale
#       QT_QPA_PLATFORM dies before any window appears.
#   (2) Empty XAUTHORITY — xcb needs an auth file; default to ~/.Xauthority.
#   (3) lo capture permission — dumpcap caps must allow capture on lo
#       (probed first; gives the exact setcap remediation).
# All GUI stderr lands in state/logs/wireshark-gui.log for triage.
launch_wireshark() {
    command -v wireshark >/dev/null 2>&1 || {
        echo "  (wireshark not installed — post-hoc: see the S11 one-liner below)"; return 0; }
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || {
        echo "  (no DISPLAY/WAYLAND_DISPLAY — post-hoc: wireshark -r \"\$(scripts/testing/newest.sh 'state/spool/pcaps/*.pcap')\" -d udp.port==10000-20000,rtp)"; return 0; }
    if ! timeout 2 dumpcap -i lo -a duration:1 -w "${TMPDIR}/mvno-ws-perm.pcap" >/dev/null 2>&1; then
        echo "  ⚠ no lo capture permission — GUI opens but capture would be empty."
        echo "    fix: sudo setcap cap_net_raw,cap_net_admin+eip \$(command -v dumpcap)"
    fi
    rm -f "${TMPDIR}/mvno-ws-perm.pcap"
    local plat="xcb"
    [ -n "${WAYLAND_DISPLAY:-}" ] && plat="wayland"
    local xa=":"
    [ "${plat}" = "xcb" ] && xa="${XAUTHORITY:-$HOME/.Xauthority}"
    # Multi-Interface capture: capture 'any' so LAN (Android phone), container bridge, and localhost are all captured.
    local iface="any"
    local cap_filter="port 5060 or port 5061 or port 2775 or port 2076 or port 8080 or port 8081 or port 8000 or port 8008 or (udp portrange 10000-20000)"
    mkdir -p state/logs
    setsid nohup env QT_QPA_PLATFORM="$plat" DISPLAY="${DISPLAY:-}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XAUTHORITY="$xa" \
        wireshark -k -i "$iface" -f "$cap_filter" \
        -d "udp.port==10000-20000,rtp" -Y "sip || smpp || rtp || http" >> state/logs/wireshark-gui.log 2>&1 &
    echo "  🦈 Wireshark GUI launched detached (interface=${iface}, Qt platform=${plat}) — errors: state/logs/wireshark-gui.log"
    echo "  Filter: SIP (5060), Asterisk (5061), SMPP (2775/2076), RTP (10000-20000), REST APIs (8080/8081/8000)"
}

[ "${GUI_CAP}" -eq 1 ] && launch_wireshark

# launch_windowed — pop the cockpit up as a VISIBLE desktop window: launch a
# terminal emulator that attaches to the tmux session (the session itself stays
# detached/deterministic; only the VIEW is brought to the screen). Guarded:
# requires DISPLAY/WAYLAND_DISPLAY + at least one known emulator; a headless
# run prints the tmux-attach hint and returns (proof harness unaffected). The
# emulator is nohup'd so demo_live.sh returns while the window keeps the
# cockpit live on the desktop.
launch_windowed() {
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || {
        echo "  (--windowed ignored: no DISPLAY/WAYLAND_DISPLAY — run 'tmux attach -t ${SESSION}' in any terminal)"
        return 0
    }
    local inner="tmux attach -t ${SESSION}; exec bash"
    local emu
    for emu in konsole kitty alacritty gnome-terminal xterm; do
        command -v "$emu" >/dev/null 2>&1 || continue
        case "$emu" in
            konsole)        nohup "$emu" --nofork -e bash -c "$inner" >/dev/null 2>&1 & ;;
            gnome-terminal) nohup "$emu" -- bash -c "$inner" >/dev/null 2>&1 & ;;
            *)              nohup "$emu" -e bash -c "$inner" >/dev/null 2>&1 & ;;
        esac
        echo "  🖥  launched ${emu} window attached to ${SESSION} (detach: Ctrl-b d, then close)"
        return 0
    done
    echo "  (--windowed: no terminal emulator found — run 'tmux attach -t ${SESSION}' manually)"
}

if [ "${WINDOWED}" -eq 1 ]; then
    launch_windowed
elif [ -t 1 ]; then
    tmux attach -t "$SESSION" || true
fi
