#!/usr/bin/env bash
# ==============================================================================
# cockpit_proof.sh — repeatable run-evidence for the tmux demo cockpit
# ==============================================================================
# Proves demo_live.sh works END-TO-END without an interactive human, in the
# same spirit as sms_matrix.sh: exit 0 only when every assertion passes, and
# the whole run is tee'd to docs/evidence/demo-cockpit-<date>.log.
#
#   bash scripts/testing/cockpit_proof.sh             # deterministic proof
#   bash scripts/testing/cockpit_proof.sh --live-mic  # + interactive mic pass
#
# What it proves:
#   [1] cockpit launches -> mvno-live session, 3 windows x 4 panes (max-4-screen)
#   [2] pane startup markers (live_tap daemon polling, kamailio, watch loops…)
#   [3] mid-call evidence within the REALTIME_AUDIO budget: a fresh pcap, a
#       live-*.wav chunk, an archived/*.txt transcript, and >0 RTP frames
#       decoded on the relay range (Issue 4.2 decode quirk respected)
#   [4] --live-mic: a genuine fresh mic capture; if ASR hears nothing, the
#       silence is ANNOTATED with one symbol per second (silence_mark.sh) —
#       PASS-with-note, never a hard fail (the raw WAV + empty .txt stay as
#       the honest primary evidence). mic_verify.sh graduation stays strict.
#   [5] teardown: session gone, baresip rigs removed
#
# Deterministic by design: the cockpit's P0 runs demo_call.sh setup+dial
# itself; the caller leg falls back to the tone caller when no Pulse socket
# exists, so the proof does not depend on the operator speaking.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
source "$REPO_ROOT/scripts/lib/common.sh"

LOG="docs/evidence/demo-cockpit-$(date +%F).log"
mkdir -p docs/evidence
MARK="/tmp/cockpit-proof-$$.mark"
MODE="${1:-}"
SESSION=mvno-live
PASS=1

# Guaranteed teardown: even if an assertion aborts mid-proof (set -e), the
# cockpit session + baresip rigs must not leak. demo_live.sh --down is
# idempotent. Also releases the registry proof-lock (acquired in main — the
# acquire helper's own EXIT trap is superseded by this one, so release here).
# NOTE: main runs in a pipeline subshell (`main | tee`), so cleanup may fire
# twice (subshell EXIT + top-level EXIT) — every step is idempotent by design.
cleanup() {
    release_run_lock mvno-cockpit.lock || true
    bash scripts/demo/demo_live.sh --down >/dev/null 2>&1 || true
    rm -f "$MARK"
}
trap cleanup EXIT

fail() { echo "  ✗ $*"; PASS=0; }
ok()   { echo "  ✓ $*"; }

pane_has() {  # $1 = win.pane  $2 = grep pattern
    tmux capture-pane -t "${SESSION}:$1" -p 2>/dev/null | grep -qE "$2"
}
# pane_has_retry — a pane can still be initializing when we first capture (a
# slow daemon or a long preflight line). Sample up to $PM_TRIES×$PM_WAIT before
# declaring a marker missing, so a healthy cockpit never hard-fails on timing.
PM_TRIES=6
PM_WAIT=3
pane_has_retry() {  # $1 = win.pane  $2 = grep pattern
    local t
    for t in $(seq 1 "$PM_TRIES"); do
        pane_has "$1" "$2" && return 0
        sleep "$PM_WAIT"
    done
    return 1
}

# locate <role> — demo_live.sh writes a version-proof role→pane-id map
# (${TMPDIR}/mvno-cockpit-panes.map) because tmux renumbers pane INDEXES by
# layout (not creation order). Resolve the pane id to win.pane_index live.
# IMPORTANT: the pane id must be targeted BARE ("%1") — the "session:%1"
# form is parsed as a WINDOW target, silently falls back to the current
# pane (window 0, pane 0) on failure, and makes every role resolve to 0.0.
PANEMAP="${TMPDIR:-/tmp}/mvno-cockpit-panes.map"
locate() {  # $1 = role (P0..P4/P3/P5/P7/watchdog/S1..S4)
    local id
    id="$(awk -F'|' -v r="$1" '$3==r {print $2; exit}' "$PANEMAP" 2>/dev/null)"
    [ -n "$id" ] && tmux display -t "${id}" -p '#{window_index}.#{pane_index}' 2>/dev/null
}

main() {
    echo "================================================================"
    echo "COCKPIT PROOF — demo_live.sh run-evidence ($(date '+%F %T'))"
    echo "  mode: ${MODE:-deterministic (tone caller)}"
    echo "================================================================"

    # --- Preconditions (fail-fast) ---
    for c in mvno-rtpengine mvno-api mvno-kamailio; do
        podman ps --format '{{.Names}}' | grep -qx "$c" || { echo "FATAL: ${c} not Up — run make up first"; return 1; }
    done
    command -v tmux >/dev/null 2>&1 || { echo "FATAL: tmux required"; return 1; }
    if [ -f "${TMPDIR:-/tmp}/mvno-live-demo.lock" ] && [ -s "${TMPDIR:-/tmp}/mvno-live-demo.lock" ]; then
        echo "FATAL: live_demo.sh lock held — refusing to collide"; return 1
    fi
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "  pre-existing ${SESSION} found — tearing down first"
        bash scripts/demo/demo_live.sh --down >/dev/null 2>&1 || true
    fi
    # Registry proof-lock FIRST (so no concurrent producer can be mid-write
    # when the pre-clean runs below). The watchdog's run_in_flight skips
    # recovery while a proof holds it. Re-register the cleanup trap — acquire
    # registered its own.
    acquire_run_lock mvno-cockpit.lock || { echo "FATAL: another run is in flight"; return 1; }
    trap cleanup EXIT
    # Risk-1 fix (stale-evidence false-PASS): in deterministic mode we own the
    # spool, so delete the artifacts THIS cockpit produces (live chunks, their
    # archived transcripts, pcaps) left by a previous untorn-down demo — then
    # anything NEWER than MARK can only have been produced by THIS proof.
    # Scope is deliberately tight: only the cockpit's own stems are removed.
    # mic_call_* (prior --live-mic recordings) and non-live archived evidence
    # are PRESERVED (the -newer "$MARK" check guards this mode regardless:
    # MARK is touched after teardown, so pre-proof files never match).
    if [ "${MODE}" != "--live-mic" ]; then
        rm -f state/spool/live-*.wav state/spool/archived/live-*.txt \
              state/spool/pcaps/*.pcap
        echo "  pre-cleaned stale cockpit evidence (deterministic mode)"
    fi
    touch "$MARK"   # freshness baseline: only evidence NEWER than this counts

    # --- Launch the cockpit (non-interactive: no tty -> no attach) ---
    echo "[1/5] launching cockpit…"
    nohup bash scripts/demo/demo_live.sh >/tmp/cockpit-proof-launch.log 2>&1 &
    LAUNCH_PID=$!

    # --- Wait for the session + 12 panes / 3 windows (bounded; preflight first) ---
    echo "[2/5] waiting for session + 3 windows x 4 panes (≤180s)…"
    SESSION_OK=0
    for i in $(seq 1 36); do
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            N="$(tmux list-panes -s -t "$SESSION" 2>/dev/null | wc -l)"
            W="$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
            if [ "${N}" -ge 12 ]; then
                SESSION_OK=1
                ok "session ${SESSION} up with ${N} panes / ${W}(t≈$((i * 5))s)"
                break
            fi
        fi
        sleep 5
    done
    if [ "${SESSION_OK}" -ne 1 ]; then
        echo "FATAL: cockpit session did not spawn in 180s — launch log:"
        tail -5 /tmp/cockpit-proof-launch.log
        bash scripts/demo/demo_live.sh --down >/dev/null 2>&1 || true
        return 1
    fi
    # Hard guard: max 4 panes per window (the "never more than 4 terminals on
    # screen" contract) — windows call/monitors/sms must each have exactly 4.
    PERWIN_PASS=1
    for w in call monitors sms; do
        PW="$(tmux list-panes -t "$SESSION:$w" 2>/dev/null | wc -l)"
        if [ "${PW}" -eq 4 ]; then
            ok "window '${w}' = ${PW} panes (≤4 per screen)"
        else
            PERWIN_PASS=0
            echo "  ✗ window '${w}' has ${PW} panes — expected exactly 4"
        fi
    done
    [ "${PERWIN_PASS}" -eq 1 ] || fail "per-window 4-pane cap violated"

    # --- Pane startup markers (key panes; tolerant of timing) ---
    echo "[3/5] sampling panes for startup markers…"
    sleep 10   # let the panes initialize before capture
    MATCH=0
    # mark <role> <pattern> <label> — tolerant sampler (resolves pane via map).
    mark() {
        local wp
        wp="$(locate "$1")"
        if [ -z "$wp" ]; then
            echo "  ~ $3: pane role '$1' not in map (${PANEMAP})"
            return 0
        fi
        pane_has_retry "$wp" "$2" && { ok "$3"; MATCH=$((MATCH + 1)); } \
            || { echo "  ~ $3 marker not visible yet (${wp})"; }
    }
    # P1 (live_tap daemon) is load-bearing — hard assert.
    WP="$(locate P1)"
    if [ -n "$WP" ]; then
        pane_has_retry "$WP" "live_tap daemon: polling" && { ok "P1 live_tap daemon polling"; MATCH=$((MATCH + 1)); } \
            || fail "P1 live_tap daemon marker missing"
    else
        fail "P1 pane not found in cockpit map (${PANEMAP})"
    fi
    # P2 capture pane is also expected (fall back to tolerant if not mapped).
    WP="$(locate P2)"
    if [ -n "$WP" ]; then
        pane_has_retry "$WP" "Capturing|tshark|live capture|pcap" && { ok "P2 capture pane active"; MATCH=$((MATCH + 1)); } \
            || fail "P2 capture marker missing"
    else
        echo "  ~ P2 pane not in map yet"
    fi
    mark P0 "SPEAK NOW|TALK NOW|setup|dial|baresip"    "P0 caller pane active"
    mark P4 "NativeVosk|AI transcript verdict|LIVE transcript|Every 2" "P4 Vosk LIVE transcript+verdict watch"
    mark P3 "REGISTER|INTERCEPT|SIP/2.0|kamailio"        "P3 kamailio logs"
    mark P5 "vosk_blocked|rtpengine|Every 2"             "P5 metrics watch"
    mark P7 "state/spool|wav|txt|archived"               "P7 evidence watch"
    mark watchdog "watchdog.log|ALL HEALTHY|mvno-stack"  "watchdog log pane"
    mark S1 "send_rest_sms|sms_matrix|MO|SMS window"     "S1 SMS MO tools"
    mark S2 "mvno_bridge_sms|smsc.db|bridge SMS"         "S2 smsc.db + bridge counters"
    mark S3 "sms|SMS|155"                                "S3 MT 2G receipts"
    mark S4 "ims_rx|receiver|5G/IMS"                     "S4 MT 5G/IMS receiver"
    [ "${MATCH}" -ge 8 ] && ok "pane markers: ${MATCH}/12 core matched" || fail "only ${MATCH}/12 pane markers"

    # --- Mid-call evidence (fresh pcap + live WAV + archived txt + RTP) ---
    echo "[4/5] waiting for mid-call evidence (≤180s, REALTIME_AUDIO budget)…"
    WAV=""; TXT=""; PCAP=""
    for i in $(seq 1 36); do
        # live-*.wav: the live_tap chunk lands in the spool root first, then the
        # Vosk spool watcher moves it (+ its transcript) into archived/ within
        # seconds — search both so a fast watcher can't starve the assertion.
        WAV="$(find state/spool state/spool/archived -maxdepth 1 -name 'live-*.wav' -newer "$MARK" 2>/dev/null | head -1 || true)"
        # Scope to live-*.txt: the mic_probe transcript also lands in archived/
        # (newer than MARK, it would otherwise be picked up first — but it
        # proves the probe, not the call; the call transcript must be this).
        TXT="$(find state/spool/archived -name 'live-*.txt' -newer "$MARK" 2>/dev/null | head -1 || true)"
        PCAP="$(find state/spool/pcaps -name '*.pcap' -newer "$MARK" 2>/dev/null | head -1 || true)"
        [ -n "$WAV" ] && [ -n "$TXT" ] && [ -n "$PCAP" ] && break
        sleep 5
    done
    [ -n "$WAV" ]  && ok "live-*.wav chunk: $(basename "$WAV")"  || fail "no live-*.wav chunk within 180s"
    [ -n "$TXT" ]  && ok "archived transcript: $(basename "$TXT")" || fail "no archived/*.txt within 180s"
    [ -n "$PCAP" ] && ok "fresh pcap: $(basename "$PCAP")"        || fail "no pcap within 180s"
    if [ -n "$PCAP" ]; then
        # tshark exits non-zero on the pcap's benign "cut short in the middle
        # of a packet" trailing-partial-packet warning — the frames are still
        # decoded. `|| true` keeps that warning from aborting the proof under
        # set -e + pipefail (the bug that leaked the session on the first run).
        RTP_N="$(tshark -r "$PCAP" -d "udp.port==10000-20000,rtp" -Y rtp 2>/dev/null | wc -l || true)"
        [ "${RTP_N:-0}" -gt 0 ] && ok "tshark decoded ${RTP_N} RTP frames (30000 range)" \
            || fail "no RTP frames decoded from fresh pcap"
    fi

    # --- Interactive mic pass (opt-in; silence-tolerant) ---
    if [ "${MODE}" = "--live-mic" ]; then
        echo "[4b] interactive mic pass — SPEAK NOW (${MIC_DUR:-10}s)…"
        bash scripts/testing/mic_record.sh "${MIC_DUR:-10}" >/dev/null 2>&1 || true
        # The Vosk spool watcher ARCHIVES (moves) the WAV within seconds of
        # landing — search both the spool root and the archive so a fresh
        # capture is found wherever the watcher left it.
        MIC_WAV="$(find state/spool state/spool/archived -maxdepth 1 -name 'mic_call_*.wav' -newer "$MARK" 2>/dev/null | head -1 || true)"
        MIC_TXT=""
        for i in $(seq 1 6); do   # ≤30s for the Vosk spool watcher to archive
            MIC_TXT="$(find state/spool/archived -name 'mic_call_*.txt' -newer "$MARK" 2>/dev/null | head -1 || true)"
            [ -n "$MIC_TXT" ] && break
            sleep 5
        done
        if [ -n "$MIC_WAV" ]; then
            if [ -s "$MIC_TXT" ]; then
                ok "mic transcript NON-EMPTY — real-voice headline proven"
                bash scripts/testing/silence_mark.sh "$MIC_WAV" "$MIC_TXT" "caller/you" || true
            else
                echo "  ✓ mic live & captured ($(basename "$MIC_WAV")) but no speech detected:"
                bash scripts/testing/silence_mark.sh "$MIC_WAV" "$MIC_TXT" "caller/you" || true
                echo "  (PASS-with-note: real-voice headline not proven this run)"
            fi
        else
            fail "no mic capture produced"
        fi
    fi

    # --- Teardown + verdict ---
    echo "[5/5] teardown…"
    bash scripts/demo/demo_live.sh --down >/dev/null 2>&1 || true
    tmux has-session -t "$SESSION" 2>/dev/null && { fail "session still exists after --down"; } || ok "session torn down"
    podman ps --format '{{.Names}}' | grep -q baresip && { fail "baresip rigs still present"; } || ok "baresip rigs removed"
    rm -f "$MARK"

    if [ "${PASS}" -eq 1 ]; then
        echo "✅ COCKPIT PROOF PASS — evidence: docs/evidence/$(basename "$LOG")"
        return 0
    fi
    echo "❌ COCKPIT PROOF FAIL — see docs/evidence/$(basename "$LOG")"
    return 1
}

# Tee the whole run to the evidence log while preserving the exit code.
set -o pipefail
main 2>&1 | tee "$LOG"
exit ${PIPESTATUS[0]}
