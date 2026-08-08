#!/usr/bin/env bash
# ==============================================================================
# preflight_5g.sh — Issue 5.8/5.9 family preflight probe (5G SA user plane)
# ==============================================================================
# Kills the recurring "downlink dead, uplink healthy" regression class
# (ISSUES.md 5.8 / 5.9: stale gNB F-TEID -> UPF DL FAR far->gnode == NULL ->
# silent GTP-U buffering) BEFORE a demo/call wires up: this probe reads ue-1's
# LIVE uesimtun0 IP (never a hardcoded stale one), drives a real UAS REGISTER
# over the 5G path, and asserts the GTP-U DOWNLINK actually emits
# (iptables OUTPUT dport 2152 delta on mvno-upf — the REGISTER 200 OK reply
# is itself a downlink G-PDU, so REGISTER-200 without 2152 movement is the
# exact 5.9 signature: uplink alive, downlink buffered).
#
# Auto-recovery (demo path only — the gate oracle stays deterministic):
#   --auto-recover / PREFLIGHT_AUTO_RECOVER=1  engage the bounded escalation
#   ladder on probe failure:
#     stage 1/2: podman restart mvno-ueransim-ue-1 (Issue 5.9/7.3 fresh PFCP
#                session carries the gNB F-TEID) -> re-probe
#     stage 2/2: atomic UERANSIM trio recreate (Issue 7.4 — NEVER recreate a
#                single UERANSIM container) -> wait ran_ue==3 -> re-probe
#     still failing -> the actionable message + exit 1
#   The NRF assertion is NOT auto-recovered (it is SBI config drift, not a
#   UE-attach race — restarting UEs cannot fix it).
#   Default (--no-recover) prints the failure and exits — byte-identical
#   behavior for make gate / GRADUATION determinism (VERIFICATION_MODEL).
#
# Exit codes:
#   0  -> 5G user plane UP (REGISTER 200 OK over uesimtun0 + GTP-U DL emitted)
#   1  -> probe failed; message says whether to restart the UE (5.9) or the
#         core (5.8 stale-session family)
#   2  -> usage/environment error (unknown flag, etc.)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

KAM_IP=10.89.0.23
KAM_PORT=5060
AOR=15559998888

say()  { echo -e "\033[0;36m[preflight-5g]\033[0m $*"; }
fail() { echo -e "\033[0;31m[preflight-5g] FAIL: $*\033[0m" >&2; exit 1; }

# --- 0. Flags ----------------------------------------------------------------
AUTO_RECOVER=0
for arg in "$@"; do
    case "$arg" in
        --auto-recover) AUTO_RECOVER=1 ;;
        --no-recover)   AUTO_RECOVER=0 ;;
        -h|--help)
            echo "Usage: $0 [--auto-recover|--no-recover]   (env: PREFLIGHT_AUTO_RECOVER=1)" >&2
            exit 0 ;;
        *) echo "Unknown flag: $arg (usage: --auto-recover | --no-recover)" >&2; exit 2 ;;
    esac
done
[ "${PREFLIGHT_AUTO_RECOVER:-0}" = "1" ] && AUTO_RECOVER=1

# --- 1. Container + tool preconditions --------------------------------------
podman ps --format '{{.Names}}' | grep -qx mvno-ueransim-ue-1 || fail "mvno-ueransim-ue-1 not running"
podman ps --format '{{.Names}}' | grep -qx mvno-upf          || fail "mvno-upf not running"

# ==============================================================================
# userplane_up — steps 2-6 of the probe, as a re-probeable unit.
# Returns 0 when the 5G user plane is UP, 1 when it failed (reason printed).
# ==============================================================================
userplane_up() {
    # --- 2. Live UE IP (dynamic across re-attaches — never hardcode) ----------
    # Poll: after a cold start / UE restart the attach + PDU session establish
    # is async (~10-40 s; Issue 7.3 can add a spurious-second-establishment
    # retry cycle), so fail only after a bounded wait instead of racing. In
    # --auto-recover mode this same poll doubles as the post-restart wait.
    local UE_IP=""
    for _try in $(seq 1 24); do
        UE_IP=$(podman exec mvno-ueransim-ue-1 sh -c 'ip -4 addr show uesimtun0 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1' 2>/dev/null | tr -d '[:space:]' || true)
        [ -n "$UE_IP" ] && break
        sleep 5
    done
    if [ -z "$UE_IP" ]; then
        echo -e "\033[0;31m[preflight-5g] FAIL: cannot read ue-1 uesimtun0 IPv4 after 120s (5G session down — podman restart mvno-ueransim-ue-1)\033[0m" >&2
        return 1
    fi
    say "ue-1 live 5G IP: $UE_IP"

    # --- 3. Route the Kamailio edge through the 5G user plane ------------------
    podman exec mvno-ueransim-ue-1 sh -c 'ip route replace 10.89.0.23/32 dev uesimtun0 2>/dev/null' || true

    # --- 4. Ensure the GTP-U DL counting rule exists, then baseline -----------
    # The OUTPUT dport 2152 rule is a pure measurement counter (policy ACCEPT);
    # it is NOT part of the Open5GS deployment, so a cold start (container
    # recreate) wipes it. Insert idempotently or dl_count reads an empty chain
    # and the delta assertion fails even when the user plane is healthy.
    podman exec mvno-upf sh -c 'iptables -C OUTPUT -p udp --dport 2152 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p udp --dport 2152 -j ACCEPT' || true
    dl_count() {
        podman exec mvno-upf sh -c 'iptables -L OUTPUT -nv 2>/dev/null | awk "/dpt:2152/{print \$1; exit}"' 2>/dev/null | tr -d '[:space:]' || true
    }
    local DL_BEFORE="$(dl_count)"; DL_BEFORE="${DL_BEFORE:-0}"
    say "GTP-U DL baseline (iptables OUTPUT 2152): ${DL_BEFORE} pkts"

    # --- 5. UAS REGISTER over the 5G path (uplink + downlink dialog) -----------
    podman cp "${SCRIPT_DIR}/sip_traffic_sim.py" mvno-ueransim-ue-1:/tmp/sip_traffic_sim.py >/dev/null 2>&1 || true
    podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true
    podman exec mvno-ueransim-ue-1 sh -c "rm -f /tmp/uas.log; nohup python3 -u /tmp/sip_traffic_sim.py --uas ${AOR} --host ${KAM_IP} --port ${KAM_PORT} --bind-ip ${UE_IP} --listen-port 5070 > /tmp/uas.log 2>&1 &" || true
    sleep 5
    local UAS_LOG
    UAS_LOG=$(podman exec mvno-ueransim-ue-1 cat /tmp/uas.log 2>/dev/null || true)
    local DL_AFTER="$(dl_count)"; DL_AFTER="${DL_AFTER:-0}"
    podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true

    # --- 6. Assertions ---------------------------------------------------------
    if ! echo "$UAS_LOG" | grep -q "SIP REGISTER 200 OK for subscriber ${AOR}"; then
        echo -e "\033[0;31m[preflight-5g] FAIL: 5G-path REGISTER did not return 200 OK (uplink/dialog broken). UAS log:\n${UAS_LOG}\033[0m" >&2
        return 1
    fi
    say "REGISTER 200 OK over 5G user plane (uesimtun0 ${UE_IP})"

    if [ "${DL_AFTER}" -le "${DL_BEFORE}" ]; then
        echo -e "\033[0;31m[preflight-5g] FAIL: GTP-U downlink did NOT emit: OUTPUT 2152 ${DL_BEFORE}->${DL_AFTER} (Issue 5.9 signature — uplink OK, DL buffered). Fix: podman restart mvno-ueransim-ue-1 (fresh PFCP session carries the gNB F-TEID)\033[0m" >&2
        return 1
    fi
    say "GTP-U downlink emitted: OUTPUT 2152 ${DL_BEFORE}->${DL_AFTER} pkts"
    return 0
}

# ==============================================================================
# check_nrf — step 7 (SBI advertisement eval). NOT auto-recovered: NRF drift is
# config, not a UE-attach race, so the recovery ladder must not fire on it.
# ==============================================================================
check_nrf() {
    local NRF_TYPES
    if ! NRF_TYPES=$(python3 "${SCRIPT_DIR}/nrf_registration.py"); then
        echo -e "\033[0;31m[preflight-5g] FAIL: NRF registration assertion failed: ${NRF_TYPES}\033[0m" >&2
        return 1
    fi
    say "NRF registrations OK (9 NFs): ${NRF_TYPES} — UPF via static PFCP peer (smf.yaml), not NRF-advertised"
    return 0
}

pass_now() {
    echo -e "\033[0;32m[preflight-5g] PASS — 5G user plane UP (REGISTER 200 OK + GTP-U DL + NRF 9/9)\033[0m"
    exit 0
}

# --- 7. First attempt ---------------------------------------------------------
if userplane_up; then
    if check_nrf; then pass_now; fi
    exit 1   # NRF failure is never auto-recovered
fi

# User plane failed here.
if [ "$AUTO_RECOVER" -ne 1 ]; then
    exit 1   # failure already printed by userplane_up (gate oracle path)
fi

# ==============================================================================
# Auto-recovery ladder (demo path only — opt-in, bounded, always re-probes)
# ==============================================================================
say "probe failed — engaging auto-recovery ladder (--auto-recover)"

# --- Stage 1/2: restart ue-1 (Issue 5.9 / 7.3) --------------------------------
say "recovery stage 1/2: podman restart mvno-ueransim-ue-1 (fresh PFCP session carries the gNB F-TEID)"
if ! podman restart mvno-ueransim-ue-1; then
    fail "podman restart mvno-ueransim-ue-1 failed — cannot auto-recover"
fi
say "re-probing after ue-1 restart (the IP poll bounds the re-attach wait)..."
if userplane_up; then
    if check_nrf; then pass_now; fi
    exit 1
fi

# --- Stage 2/2: atomic UERANSIM trio recreate (Issue 7.4) ---------------------
say "recovery stage 2/2: atomic UERANSIM trio recreate (Issue 7.4 — never recreate a single UERANSIM container)"
if ! podman compose up -d --force-recreate ueransim-gnb ueransim-ue-1 ueransim-ue-2 ueransim-ue-3; then
    fail "UERANSIM trio recreate failed — cannot auto-recover"
fi
say "waiting for all 3 UEs to NAS-attach (ran_ue==3, bounded 150s)..."
for _try in $(seq 1 50); do
    N=$(curl -s 'http://localhost:8428/api/v1/query?query=ran_ue' 2>/dev/null | jq -r '.data.result[0].value[1]' 2>/dev/null || true)
    if [ "${N:-}" = "3" ]; then
        say "ran_ue=3 (all UEs attached)"
        break
    fi
    sleep 3
done
say "re-probing after trio recreate..."
if userplane_up; then
    if check_nrf; then pass_now; fi
    exit 1
fi

fail "5G user plane still DOWN after auto-recovery (stages 1+2). Manual remedies: podman restart mvno-ueransim-ue-1 (5.9), or full trio recreate (7.4): podman compose up -d --force-recreate ueransim-gnb ueransim-ue-1 ueransim-ue-2 ueransim-ue-3"
