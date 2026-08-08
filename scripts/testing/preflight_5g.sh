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
# Exit codes:
#   0  -> 5G user plane UP (REGISTER 200 OK over uesimtun0 + GTP-U DL emitted)
#   1  -> probe failed; message says whether to restart the UE (5.9) or the
#         core (5.8 stale-session family)
#   2  -> usage/environment error (ue-1 container missing, no iptables, etc.)
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

# --- 1. Container + tool preconditions --------------------------------------
podman ps --format '{{.Names}}' | grep -qx mvno-ueransim-ue-1 || fail "mvno-ueransim-ue-1 not running"
podman ps --format '{{.Names}}' | grep -qx mvno-upf          || fail "mvno-upf not running"

# --- 2. Live UE IP (dynamic across re-attaches — never hardcode) ------------
UE_IP=$(podman exec mvno-ueransim-ue-1 sh -c 'ip -4 addr show uesimtun0 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1' | tr -d '[:space:]')
[ -n "$UE_IP" ] || fail "cannot read ue-1 uesimtun0 IPv4 (5G session down — podman restart mvno-ueransim-ue-1)"
say "ue-1 live 5G IP: $UE_IP"

# --- 3. Route the Kamailio edge through the 5G user plane --------------------
podman exec mvno-ueransim-ue-1 sh -c 'ip route replace 10.89.0.23/32 dev uesimtun0 2>/dev/null' || true

# --- 4. Baseline GTP-U downlink counter (iptables OUTPUT dport 2152) ---------
dl_count() {
    podman exec mvno-upf sh -c 'iptables -L OUTPUT -nv 2>/dev/null | awk "/dpt:2152/{print \$1; exit}"' 2>/dev/null | tr -d '[:space:]'
}
DL_BEFORE="$(dl_count)"; DL_BEFORE="${DL_BEFORE:-0}"
say "GTP-U DL baseline (iptables OUTPUT 2152): ${DL_BEFORE} pkts"

# --- 5. UAS REGISTER over the 5G path (uplink + downlink dialog) -------------
podman cp "${SCRIPT_DIR}/sip_traffic_sim.py" mvno-ueransim-ue-1:/tmp/sip_traffic_sim.py >/dev/null
podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true
podman exec mvno-ueransim-ue-1 sh -c "rm -f /tmp/uas.log; nohup python3 -u /tmp/sip_traffic_sim.py --uas ${AOR} --host ${KAM_IP} --port ${KAM_PORT} --bind-ip ${UE_IP} --listen-port 5070 > /tmp/uas.log 2>&1 &"
sleep 5
UAS_LOG=$(podman exec mvno-ueransim-ue-1 cat /tmp/uas.log 2>/dev/null || true)
DL_AFTER="$(dl_count)"; DL_AFTER="${DL_AFTER:-0}"
podman exec mvno-ueransim-ue-1 pkill -f sip_traffic_sim 2>/dev/null || true

# --- 6. Assertions -----------------------------------------------------------
echo "$UAS_LOG" | grep -q "SIP REGISTER 200 OK for subscriber ${AOR}" \
    || fail "5G-path REGISTER did not return 200 OK (uplink/dialog broken). UAS log:\n${UAS_LOG}"
say "REGISTER 200 OK over 5G user plane (uesimtun0 ${UE_IP})"

[ "${DL_AFTER}" -gt "${DL_BEFORE}" ] || fail "GTP-U downlink did NOT emit: OUTPUT 2152 ${DL_BEFORE}->${DL_AFTER} (Issue 5.9 signature — uplink OK, DL buffered). Fix: podman restart mvno-ueransim-ue-1 (fresh PFCP session carries the gNB F-TEID)"
say "GTP-U downlink emitted: OUTPUT 2152 ${DL_BEFORE}->${DL_AFTER} pkts"

# --- 7. NRF registration assertion (ROADMAP item 5: SBI advertisement eval) --
# All control-plane NFs must be registered with the NRF (Nnrf_NFM discovery,
# HTTP/2 h2c on nrf:7777 — queried via mvno-grafana, the curl-capable probe
# container on mvno_net). Catches advertise/uri config drift before demos.
# UPF is intentionally NOT NRF-registered: smf.yaml uses a static PFCP peer
# (client.upf: address: upf) for deterministic UPF selection — see ROADMAP 5.
if ! NRF_TYPES=$(python3 "${SCRIPT_DIR}/nrf_registration.py"); then
    fail "NRF registration assertion failed: ${NRF_TYPES}"
fi
say "NRF registrations OK (9 NFs): ${NRF_TYPES} — UPF via static PFCP peer (smf.yaml), not NRF-advertised"

echo -e "\033[0;32m[preflight-5g] PASS — 5G user plane UP (REGISTER 200 OK + GTP-U DL ${DL_BEFORE}->${DL_AFTER} + NRF 9/9)\033[0m"
exit 0
