#!/usr/bin/env bash
# ==============================================================================
# MVNO End-to-End SMS Interworking Runbook - Goal 7
# ==============================================================================
# Verifies the FULL 4-cell SMS interworking matrix across the 2G and 5G domains
# plus a deterministic AI-block policy path, asserting on LIVE metrics:
#
#   Cell      | From              | To                | Routed via
#   ----------+-------------------+-------------------+----------------------------
#   2G->2G    | 15554443322 (MS1) | 15557778888 (MS2) | 2G SMSC direct (no bridge)
#   2G->5G    | 15554443322 (MS1) | 15551234567 (UE1) | IP-SM-GW poll -> SIP -> 5G
#   5G->2G    | 15551234567 (UE1) | 15554443322 (MS1) | IP-SM-GW :5090 -> SMPP
#   5G->5G    | 15551234567 (UE1) | 15557654321 (UE2) | Kamailio IMS twin relay
#   AI-BLOCK  | 15554443322 (MS1) | 15551234567 (UE1) | mock allow:false on marker
#
# Deterministic AI-block: inline mvno-ai-filter mock (docker-compose.yml) returns
# {"allow":false} when body contains E2E-BLOCK, else {"allow":true}. Config-only.
#
# Gate: every cell must PASS or the script exits non-zero at first failure.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

PASS=0; FAIL=0
TS="$(date +%H%M%S)"

BRIDGE_METRICS="http://localhost:9100/metrics"
VM="http://localhost:8428/api/v1/query"

UE1=mvno-ueransim-ue-1
UE2=mvno-ueransim-ue-2
# Kamailio must be able to route relays back to a receiver.  The UE's 5G tun IP
# (10.45.0.x) is NOT reachable from Kamailio on mvno_net, so receivers register
# with their bridge-network eth0 IP (reachable by Kamailio) for determinism.
UE1_IP=10.89.0.31   # eth0 on mvno_net (reachable by Kamailio)
UE2_IP=10.89.0.32
KAM=10.89.0.23
KAM_PORT=5060

ok()  { echo -e "${GREEN}  ok  $1${NC}"; PASS=$((PASS+1)); }
bad() { echo -e "${RED}  X   $1${NC}"; FAIL=$((FAIL+1)); }

bridge_counter() { curl -s -m 5 "${BRIDGE_METRICS}" | awk -v m="$1" '$1==m {print $2; exit}'; }
vm_value() {
  curl -s -m 5 "${VM}?query=$1" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); r=d.get("data",{}).get("result",[])
    print(r[0]["value"][1] if r else "")
except Exception: print("")'
}
section() { echo -e "${CYAN}==== $1 ====${NC}"; }

echo -e "${CYAN}==== GOAL 7 : End-to-End SMS Interworking (4-cell + AI-block) ====${NC}"

# -----------------------------------------------------------------------------
# Preconditions: bridge up, script copied into UEs
# -----------------------------------------------------------------------------
section "Preflight"
podman cp "${SCRIPT_DIR}/ims_terminal.py" "${UE1}:/ims_terminal.py" 2>/dev/null || true
podman cp "${SCRIPT_DIR}/ims_terminal.py" "${UE2}:/ims_terminal.py" 2>/dev/null || true
if [ -z "$(bridge_counter mvno_bridge_sms_attempts_total || true)" ]; then
  echo -e "${RED}  X cannot reach bridge /metrics - is mvno-ip-sm-gw up on :9100?${NC}"; exit 1
fi
ok "bridge /metrics reachable"


# =============================================================================
# Cell 1 - 2G -> 2G (2G SMSC direct; bridge must NOT be involved)
# =============================================================================
section "Cell 1: 2G->2G  (15554443322 -> 15557778888, 2G SMSC direct)"
b_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b_25="${b_25:-0}"
b_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; b_52="${b_52:-0}"
python3 "${SCRIPT_DIR}/send_smpp_sms.py" --sender 15554443322 --recipient 15557778888 \
  --message "E2E 2G2G ${TS}" >/dev/null
sleep 8
a_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a_25="${a_25:-0}"
a_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; a_52="${a_52:-0}"
if [ "$a_25" = "$b_25" ] && [ "$a_52" = "$b_52" ]; then
  ok "delivered via 2G SMSC; bridge counters unchanged (2g5g=$a_25,5g2g=$a_52)"
else
  bad "bridge counters moved unexpectedly (2g5g $b_25->$a_25, 5g2g $b_52->$a_52)"
fi

# =============================================================================
# Cell 2 - 2G -> 5G (IP-SM-GW poll -> SIP MESSAGE -> 5G UE receiver)
# =============================================================================
section "Cell 2: 2G->5G  (15554443322 -> 15551234567, via IP-SM-GW)"
b25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b25="${b25:-0}"
RECV_LOG=/tmp/e2e_ue1_recv_${TS}.log
podman exec "${UE1}" python3 /ims_terminal.py --mode recv --msisdn 15551234567 \
  --host ${KAM} --port ${KAM_PORT} --bind-ip ${UE1_IP} --listen 30 \
  > "${RECV_LOG}" 2>&1 &
RECV_PID=$!
sleep 4
"${SCRIPT_DIR}/send_vty_sms.sh" 15554443322 15551234567 "E2E 2G5G ${TS}" >/dev/null 2>&1 || true
a25=""
for _ in $(seq 1 12); do
  a25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a25="${a25:-0}"
  [ "$a25" -gt "$b25" ] && break; sleep 3
done
if [ "$a25" -gt "$b25" ]; then
  ok "bridge 2g->5g counter ${b25}->${a25}"
else
  bad "bridge 2g->5g counter did not move (still ${b25})"
fi
if grep -q "E2E 2G5G ${TS}" "${RECV_LOG}" 2>/dev/null; then ok "5G UE receiver got the body"; else bad "5G UE receiver did not log the body"; fi
if podman logs mvno-ip-sm-gw 2>&1 | grep -q "DELIVERED"; then ok "bridge marked row DELIVERED"; else bad "no DELIVERED in bridge log"; fi
kill "${RECV_PID}" 2>/dev/null || true

# =============================================================================
# Cell 3 - 5G -> 2G (UE1 -> bridge SIP :5090 -> SMPP submit_sm -> 2G SMSC)
# =============================================================================
section "Cell 3: 5G->2G  (15551234567 -> 15554443322, via IP-SM-GW)"
b52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; b52="${b52:-0}"
podman exec "${UE1}" python3 /ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15554443322 --host ${KAM} --port ${KAM_PORT} --bind-ip ${UE1_IP} \
  --body "E2E 5G2G ${TS}" >/dev/null 2>&1 || true
a52=""
for _ in $(seq 1 10); do
  a52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; a52="${a52:-0}"
  [ "$a52" -gt "$b52" ] && break; sleep 3
done
if [ "$a52" -gt "$b52" ]; then
  ok "bridge 5g->2g counter ${b52}->${a52}"
else
  bad "bridge 5g->2g counter did not move (still ${b52})"
fi
if podman logs mvno-ip-sm-gw 2>&1 | grep -q "SUBMIT_SM"; then ok "bridge SMPP SUBMIT_SM to 2G SMSC"; else bad "no SUBMIT_SM in bridge log"; fi

# =============================================================================
# Cell 4 - 5G -> 5G (UE1 -> Kamailio IMS twin -> UE2 receiver)
# =============================================================================
section "Cell 4: 5G->5G  (15551234567 -> 15557654321, Kamailio IMS twin)"
RECV2=/tmp/e2e_ue2_recv_${TS}.log
podman exec -d "${UE2}" python3 /ims_terminal.py --mode recv --msisdn 15557654321 \
  --host ${KAM} --port ${KAM_PORT} --bind-ip ${UE2_IP} --listen 30 \
  > "${RECV2}" 2>&1 || true
sleep 4
podman exec "${UE1}" python3 /ims_terminal.py --mode send --msisdn 15551234567 \
  --peer 15557654321 --host ${KAM} --port ${KAM_PORT} --bind-ip ${UE1_IP} \
  --body "E2E 5G5G ${TS}" >/dev/null 2>&1 || true
found=""
for _ in $(seq 1 10); do
  grep -q "E2E 5G5G ${TS}" "${RECV2}" 2>/dev/null && { found=1; break; }; sleep 3
done
if [ -n "$found" ]; then ok "5G->5G delivered: UE2 receiver got the body"; else bad "5G->5G not received by UE2"; fi
pkill -f "ims_terminal.py --mode recv --msisdn 15557654321" 2>/dev/null || true

# =============================================================================
# Cell 5 - AI-BLOCK (mock allow:false on E2E-BLOCK marker -> dropped, not bridged)
# =============================================================================
section "Cell 5: AI-Block (E2E-BLOCK marker -> allow:false -> dropped)"
blk_b="$(vm_value 'mvno_sms_blocked_total')"; blk_b="${blk_b:-0}"
b25b="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b25b="${b25b:-0}"
python3 "${SCRIPT_DIR}/send_smpp_sms.py" --sender 15554443322 --recipient 15551234567 \
  --message "E2E-BLOCK persistent lottery spam ${TS}" >/dev/null
blk_a="$blk_b"; a25b="$b25b"
for _ in $(seq 1 12); do
  blk_a="$(vm_value 'mvno_sms_blocked_total')"; blk_a="${blk_a:-$blk_b}"
  a25b="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a25b="${a25b:-$b25b}"
  [ "$blk_a" -gt "$blk_b" ] && break; sleep 3
done
if [ "$blk_a" -gt "$blk_b" ]; then
  ok "SMS blocked counter ${blk_b}->${blk_a} (policy rejected)"
  if [ "$a25b" -eq "$b25b" ]; then
    ok "blocked SMS was NOT bridged (2g->5g stayed ${a25b})"
  else
    bad "blocked SMS leaked to bridge (2g->5g ${b25b}->${a25b})"
  fi
else
  bad "blocked counter did not move (still ${blk_b})"
fi

# =============================================================================
# Summary / hard gate
# =============================================================================
echo ""
echo -e "${CYAN}==== RESULTS : ${PASS} PASSED / ${FAIL} FAILED ====${NC}"
if [ "${FAIL}" -eq 0 ]; then
  echo -e "${GREEN}  GOAL 7 E2E - ALL CELLS PASSED${NC}"
  exit 0
else
  echo -e "${RED}  GOAL 7 E2E - ${FAIL} CELL(S) FAILED${NC}"
  exit 1
fi

