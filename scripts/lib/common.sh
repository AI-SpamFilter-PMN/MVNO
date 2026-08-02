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
