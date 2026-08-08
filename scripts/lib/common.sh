#!/usr/bin/env bash
# ==============================================================================
# scripts/lib/common.sh — shared helpers for MVNO scripts
# ==============================================================================
# Single source of truth for runtime/OS detection + logging, sourced by the
# script suite to eliminate the duplicated detect_runtime/detect_os/try_log
# blocks that had diverged across bootstrap.sh / load-offline.sh / up.sh /
# vty.sh / seed-mongo.sh (the "right-sizing" Goal-2 refactor).
#
# Usage (from any script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
#   detect_runtime   # exports COMPOSE_CMD, DOCKER_CMD, RUNTIME
# ==============================================================================

# detect_runtime — auto-detect Podman vs Docker (+ compose plugin).
# Exports: RUNTIME, DOCKER_CMD, COMPOSE_CMD. Exits 1 if none found.
detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
        DOCKER_CMD="podman"
        if podman compose version >/dev/null 2>&1; then
            COMPOSE_CMD="podman compose"
        else
            echo "  [WARN] 'podman compose' plugin missing; install docker-compose" >&2
            COMPOSE_CMD="podman compose"
        fi
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            RUNTIME="docker"
            DOCKER_CMD="docker"
            COMPOSE_CMD="docker compose"
            return 0
        fi
        if sg docker -c "docker info" >/dev/null 2>&1; then
            RUNTIME="docker"
            DOCKER_CMD="sg docker -c docker"
            COMPOSE_CMD="sg docker -c 'docker compose'"
            return 0
        fi
    fi
    echo "ERROR: No container runtime found (podman or docker with compose plugin)" >&2
    return 1
}

# detect_os — set OS to one of: arch|debian|fedora|alpine|suse|macos|unknown.
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            arch|endeavouros|cachyos|manjaro|artix) OS="arch" ;;
            debian|ubuntu|pop|linuxmint|elementary|zorin) OS="debian" ;;
            fedora|rhel|centos|rocky|alma) OS="fedora" ;;
            alpine) OS="alpine" ;;
            opensuse*|suse) OS="suse" ;;
            *) OS="unknown" ;;
        esac
    elif [ "$(uname)" = "Darwin" ]; then
        OS="macos"
    else
        OS="unknown"
    fi
    echo "Detected OS: ${ID:-unknown} (${OS})"
}

# try_log LABEL CMD — run CMD, tee to a log, track success/failure.
# Caller must define arrays SUCCESSES=() and FAILURES=() before use.
try_log() {
    local label="$1" cmd="$2" logfile
    [ -n "${LOG_DIR:-}" ] || LOG_DIR="/tmp"
    mkdir -p "$LOG_DIR"
    logfile="$LOG_DIR/${label//\//_}.log"
    echo ""
    echo "=== $label ==="
    eval "$cmd" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ $label"
        SUCCESSES+=("$label")
    else
        echo "  ✗ $label (see $logfile)"
        FAILURES+=("$label")
    fi
}

# ==============================================================================
# SINGLE SOURCE OF TRUTH — MVNO test-subscriber topology & shared AoRs
# ==============================================================================
# Every script MUST reference these constants instead of hardcoding MSISDNs.
# scripts/check-subscribers.sh enforces this against the Makefile seeds and the
# run orchestrators, so the "balance 100 vs 0" and "bridge AoR deregistered"
# drift regressions cannot recur silently.
#
# Topology (VERIFICATION_MODEL.md contract):
#   2G: MS1 15554443322 / MS2 15557778888  (bridge-owned — NEVER deregister)
#   5G: UE1 15551234567 (funded, balance 100) / UE2 15557654321 (balance 0) /
#       UAS/rig 15559998888 (shared AoR: preflight probe + live_demo UAS +
#       baresip-rx + cockpit — only ONE of them may hold it at a time)
#   rig: baresip-tx 15553332211 (4th EIR SIM)
# ==============================================================================
MVNO_UAS_AOR="15559998888"           # shared UAS/rig AoR (the collision-prone one)
MVNO_MSISDN_FUNDED="15551234567"     # UE1 — balance 100 (allowed caller)
MVNO_MSISDN_ZERO="15557654321"       # UE2 — balance 0   (SIP 403 block contract)
MVNO_MSISDN_2G=(15554443322 15557778888)          # bridge-owned 2G AoRs (5G->2G relay)
MVNO_MSISDN_5G=(15551234567 15557654321 15559998888)
MVNO_BARESIP_AORS=(15559998888 15553332211)       # cockpit rig AoRs
MVNO_EIR_SIMS=(15551234567 15559998888 15554443322 15553332211)  # live_demo [7/13]
MVNO_MSISDN_ALL=(15551234567 15557654321 15559998888 15554443322 15557778888 15553332211)
MVNO_SMSC_SHORTCODE="15550000000"    # SMSC short-code (2G MS sms-service-center) —
                                      # NOT a subscriber; must never be provisioned
MVNO_THROWAWAY="15551234999"         # DOCUMENTED EXEMPLAR only — subscriber_proof.sh
                                      # derives a TIME-UNIQUE variant (1555000+epoch)
                                      # so runs/archives can never collide on one
                                      # number; this literal is what docs/README show

# ==============================================================================
# UNIFIED RUN-LOCK REGISTRY — settle the orchestrators so they can never fight
# ==============================================================================
# Every run orchestrator registers here (gate / sms_matrix / live_demo / cockpit
# / proofs). The watchdog's in-flight guard (run_in_flight) consults this same
# registry + the tmux session + the pgrep set, so the "watchdog vs demo",
# "cockpit vs live_demo", "proof vs recovery" conflicts are impossible by
# construction instead of by a manually-synced list in each script.
# ==============================================================================
MVNO_RUN_LOCKS=(mvno-gate.lock mvno-preflight.lock mvno-sms-matrix.lock \
                mvno-live-demo.lock mvno-cockpit.lock mvno-demo-live.lock \
                mvno-subscriber-proof.lock)
# NOTE: no pgrep set by design. Every run orchestrator (gate, sms_matrix,
# live_demo, cockpit, both proofs) AND the preflight probe hold a registry lock,
# and the cockpit additionally owns its tmux session — so the lock registry +
# tmux check cover every window (incl. the cockpit's preflight, which holds
# mvno-preflight.lock). A pgrep set was tried and REJECTED: pgrep -f also
# matches wrapper processes (make's `sh -c ./scripts/testing/gate.sh`, a parent
# bash -c whose cmdline contains the invocation), which made the gate see
# itself as in-flight and refuse to start.

# acquire_run_lock NAME — staleness-aware PID lock in ${TMPDIR}. Registers a
# single EXIT trap releasing it (idempotent). Returns 1 if the lock is held by
# a live process.
#
# LIMITATION: bash supports ONE EXIT trap per process — a second acquire in the
# same process would replace the first trap and leak that lock (no caller does
# this today; every orchestrator holds exactly one lock). release_run_lock is
# available if a caller ever needs more than one.
_LOCK_NAME=""
acquire_run_lock() {
    local name="$1" f
    f="${TMPDIR:-/tmp}/${name}"
    _LOCK_NAME="$name"
    if [ -f "$f" ] && [ -s "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then
        echo "[-] Error: lock '${name}' held by PID $(cat "$f" 2>/dev/null) — refusing to collide (another run in progress)" >&2
        return 1
    fi
    echo $$ > "$f"
    trap 'rm -f "${TMPDIR:-/tmp}/'"$_LOCK_NAME"'"' EXIT
    return 0
}

# release_run_lock [NAME] — explicit release (also released by the EXIT trap).
release_run_lock() {
    rm -f "${TMPDIR:-/tmp}/${1:-$_LOCK_NAME}" 2>/dev/null || true
}

# run_in_flight — 0 when ANY registered orchestrator is active: a live lock in
# the registry, or the mvno-live tmux cockpit session. Lock-based, so it can
# never false-positive on wrapper/parent processes (see the pgrep note above).
run_in_flight() {
    local l f
    for l in "${MVNO_RUN_LOCKS[@]}"; do
        f="${TMPDIR:-/tmp}/${l}"
        if [ -f "$f" ] && [ -s "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then
            return 0
        fi
    done
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t mvno-live 2>/dev/null; then
        return 0
    fi
    return 1
}
