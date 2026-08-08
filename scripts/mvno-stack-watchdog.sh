#!/usr/bin/env bash
# ==============================================================================
# mvno-stack-watchdog.sh — continuous functional health for the MVNO stack
# ==============================================================================
# Closes the "silent-but-Up" holes that `restart: unless-stopped` cannot catch
# (it only fires on process exit, not on "process alive but function dead"):
#   - UE attachment drop     — UE container Up but PDU session gone
#     (ran_ue < 3 / no uesimtun0; Issue 5.8/5.9/7.3/7.4 family)
#   - bridge 2G-AoR loss     — mvno-ip-sm-gw Up but its 5G->2G registrations
#     (15554443322/15557778888) dead (Issue 8.38 family). The bridge's /health
#     is the authoritative signal — it reflects the last REGISTER 200 OK per
#     AoR (usrloc memory). The Kamailio sqlite location mirror is NOT used:
#     usrloc runs db_mode=2 (write-back) and lags live memory (verified live:
#     the 5G->2G relay keeps delivering with an empty mirror).
#
# The gate oracle is NEVER touched: recovery only ever runs the opt-in
# preflight_5g.sh --auto-recover ladder, and every recovery is skipped while a
# demo / gate / cockpit is in flight (lock files + tmux session + pgrep) so the
# watchdog can never fight an in-progress run.
#
# Usage:
#   bash scripts/mvno-stack-watchdog.sh --once           # one check + recover; exit 0 healthy
#   bash scripts/mvno-stack-watchdog.sh --loop           # persistent loop (systemd unit)
#   bash scripts/mvno-stack-watchdog.sh --check-bridge   # bridge AoRs only (preflight reuse)
#
# Recovery (bounded, always re-probes):
#   UE fleet degraded  -> scripts/testing/preflight_5g.sh --auto-recover
#   bridge AoRs lost   -> podman restart mvno-ip-sm-gw (re-REGISTERs at boot),
#                        then a bounded poll (<=60s) until /health is 200 again
#
# The bridge's own 30s retry loop already self-heals a transient REGISTER
# failure; the watchdog adds the persistent, out-of-band restart for the case
# where the bridge process itself is stuck (alive but function dead).
#
# Env: WATCHDOG_INTERVAL (default 30), WATCHDOG_LOG (default state/logs/watchdog.log)
# ==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

INTERVAL="${WATCHDOG_INTERVAL:-30}"
LOG_FILE="${WATCHDOG_LOG:-state/logs/watchdog.log}"
BRIDGE_AORS=(15554443322 15557778888)   # single source — the bridge's 2G AoRs
DEMO_LOCKS=(mvno-live-demo.lock mvno-sms-matrix.lock mvno-gate.lock)

mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"; }

# -----------------------------------------------------------------------------
# guards
# -----------------------------------------------------------------------------
demo_running() {
    local l f
    for l in "${DEMO_LOCKS[@]}"; do
        f="${TMPDIR:-/tmp}/${l}"
        if [ -f "$f" ] && [ -s "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then
            return 0
        fi
    done
    tmux has-session -t mvno-live 2>/dev/null && return 0
    # pgrep covers the gate/demo scripts AND the cockpit launcher: demo_live.sh
    # runs preflight_5g.sh --auto-recover BEFORE the tmux session exists, so a
    # live tmux check alone would miss that window (and two concurrent
    # preflight runs would collide on the UAS AoR 15559998888).
    pgrep -f 'scripts/(testing/(gate|sms_matrix|live_demo)|demo/demo_live)\.sh' >/dev/null 2>&1 && return 0
    return 1
}

# Platform anchor: mvno-kamailio running means the MVNO stack is up. When it is
# missing the whole platform is down (e.g. mid make clean) and the watchdog just
# waits — but a missing UE or bridge container is itself a failure to recover.
stack_up() {
    podman ps --format '{{.Names}}' | grep -qx mvno-kamailio || return 1
    return 0
}

# -----------------------------------------------------------------------------
# checks
# -----------------------------------------------------------------------------
# UE fleet healthy iff ran_ue == 3 (AMF gauge) AND every UE has a live
# uesimtun0. Mirrors the preflight probe so the two cannot disagree.
ue_fleet_ok() {
    local n u
    n="$(curl -s --max-time 5 'http://localhost:8428/api/v1/query?query=ran_ue' \
        2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || true)"
    [ "${n:-0}" = "3" ] || return 1
    for u in 1 2 3; do
        podman exec "mvno-ueransim-ue-${u}" \
            sh -c 'ip -4 addr show uesimtun0 2>/dev/null | grep -q "inet "' \
            >/dev/null 2>&1 || return 1
    done
    return 0
}

# Bridge healthy iff mvno-ip-sm-gw is Up AND its /health is 200 (both 2G AoRs
# registered in Kamailio usrloc memory). /health is the single authoritative
# signal — it tracks the bridge's last successful REGISTER per AoR, which is
# exactly what routes the 5G->2G relay.
bridge_reg_ok() {
    local code
    podman ps --format '{{.Names}}' | grep -qx mvno-ip-sm-gw || return 1
    code="$(timeout 5 curl -s -o /dev/null -w '%{http_code}' \
        http://127.0.0.1:9100/health 2>/dev/null || true)"
    [ "${code:-000}" = "200" ] || return 1
    return 0
}

# -----------------------------------------------------------------------------
# recovery (bounded; skips when a demo/gate is in flight)
# -----------------------------------------------------------------------------
recover() {
    local status=0
    if demo_running; then
        log "skip recovery: demo/gate/cockpit in progress"
        return 0
    fi
    if ! ue_fleet_ok; then
        log "UE fleet degraded (ran_ue!=3 or uesimtun0 missing) -> preflight_5g.sh --auto-recover"
        if bash scripts/testing/preflight_5g.sh --auto-recover; then
            log "UE fleet recovered"
        else
            log "ERROR: UE recovery failed after the bounded ladder — manual intervention required"
            status=1
        fi
    fi
    if ! bridge_reg_ok; then
        log "bridge /health degraded (2G AoR registrations dead) -> podman restart mvno-ip-sm-gw"
        if podman restart mvno-ip-sm-gw; then
            # Bounded poll: the container can take ~10s just to stop (SIGKILL
            # fallback) plus boot + REGISTER; a fixed sleep was provably too
            # short (observed false-negative in the induced-failure test).
            local waited=0
            while [ "${waited}" -lt 60 ]; do
                if bridge_reg_ok; then
                    log "bridge /health OK after restart (t=${waited}s)"
                    break
                fi
                sleep 5
                waited=$((waited + 5))
            done
            bridge_reg_ok || { log "ERROR: bridge /health still not 200 after restart"; status=1; }
        else
            log "ERROR: bridge restart failed"
            status=1
        fi
    fi
    return $status
}

# -----------------------------------------------------------------------------
# modes
# -----------------------------------------------------------------------------
MODE="${1:---loop}"
case "${MODE}" in
    --check-bridge)
        bridge_reg_ok; exit $? ;;
    --once)
        if ! stack_up; then log "platform not up (no mvno-kamailio) — nothing to watch"; exit 0; fi
        if ue_fleet_ok && bridge_reg_ok; then
            log "ALL HEALTHY (UE fleet ran_ue=3 + bridge AoRs registered)"
            exit 0
        fi
        log "degraded — entering recovery"
        recover
        exit $? ;;
    --loop)
        log "watchdog loop starting (interval=${INTERVAL}s, log=${LOG_FILE})"
        LAST="unknown"
        while true; do
            if stack_up; then
                if ue_fleet_ok && bridge_reg_ok; then
                    if [ "${LAST}" != "healthy" ]; then
                        log "ALL HEALTHY (UE fleet ran_ue=3 + bridge AoRs registered)"
                        LAST="healthy"
                    fi
                else
                    LAST="degraded"
                    log "degraded — entering recovery"
                    recover || true
                fi
            else
                if [ "${LAST}" != "down" ]; then
                    log "platform not up (no mvno-kamailio) — waiting"
                    LAST="down"
                fi
            fi
            sleep "${INTERVAL}"
        done ;;
    *)
        echo "usage: $0 [--loop|--once|--check-bridge]" >&2
        exit 2 ;;
esac
