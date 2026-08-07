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
# Topology note: the IMS (5G-side) senders/receivers run as DEDICATED containers on
# the bridge network (mvno_mvno_net) with their own IP, so Kamailio can route relays
# back to them (mirrors the proven Goal 6 receiver topology; does NOT depend on the
# UERANSIM 5G user-plane). 2G->5G rows are injected directly into state/hlr/smsc.db.
#
# Gate: every cell must PASS or the script exits non-zero at the summary.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# Evidence layer: durable e2e run log (Aug-6 convention) — tee the whole run.
EVIDENCE_DIR="${REPO_ROOT}/docs/evidence"
mkdir -p "${EVIDENCE_DIR}"
RUN_LOG="${EVIDENCE_DIR}/e2e-run-$(date +%F).log"
exec > >(tee -a "${RUN_LOG}") 2>&1
echo "==== e2e runbook log: ${RUN_LOG} ===="

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
TS="$(date +%H%M%S)"
BRIDGE_METRICS="http://localhost:9100/metrics"
VM="http://localhost:8428/api/v1/query"
NET="mvno_mvno_net"
KAM=10.89.0.23
KAM_PORT=5060

ok()  { echo -e "${GREEN}  ok  $1${NC}"; PASS=$((PASS+1)); }
bad() { echo -e "${RED}  X   $1${NC}"; FAIL=$((FAIL+1)); }

bridge_counter() { curl -s -m 5 "${BRIDGE_METRICS}" | awk -v m="$1" '$1==m {print $2; exit}'; }
api_counter() {
  curl -s -m 5 http://localhost:8080/actuator/prometheus | python3 -c 'import sys
want = "'$1'"
for line in sys.stdin:
    parts = line.split()
    if len(parts) == 2 and parts[0] == want:
        print(int(float(parts[1]))); break'
}
vm_value() {
  curl -s -m 5 "${VM}?query=$1" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); r=d.get("data",{}).get("result",[])
    print(r[0]["value"][1] if r else "")
except Exception: print("")'
}
section() { echo -e "${CYAN}==== $1 ====${NC}"; }

# --- dedicated mvno_net IMS terminal container helpers ---------------------
start_recv() { # name msisdn ip listen
  podman rm -f "$1" >/dev/null 2>&1 || true
  podman run -d --name "$1" --network "$NET" --ip "$3" \
    -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
    python3 /scripts/ims_terminal.py --mode recv --msisdn "$2" \
    --host ${KAM} --port ${KAM_PORT} --bind-ip "$3" --listen "$4" >/dev/null 2>&1
}
start_send() { # name msisdn peer body ip
  podman rm -f "$1" >/dev/null 2>&1 || true
  podman run -d --name "$1" --network "$NET" --ip "$5" \
    -v "${SCRIPT_DIR}:/scripts:z" python:3.11-alpine \
    python3 /scripts/ims_terminal.py --mode send --msisdn "$2" --peer "$3" \
    --host ${KAM} --port ${KAM_PORT} --bind-ip "$5" --body "$4" >/dev/null 2>&1
}
stop_ims() { podman rm -f "$1" >/dev/null 2>&1 || true; }

echo -e "${CYAN}==== GOAL 7 : End-to-End SMS Interworking (4-cell + AI-block) ====${NC}"

# -----------------------------------------------------------------------------
# Preconditions: bridge /metrics reachable
# -----------------------------------------------------------------------------
section "Preflight"
if [ -z "$(bridge_counter mvno_bridge_sms_attempts_total || true)" ]; then
  echo -e "${RED}  X cannot reach bridge /metrics - is mvno-ip-sm-gw up on :9100?${NC}"; exit 1
fi
ok "bridge /metrics reachable"

if [ -z "$(api_counter mvno_sms_blocked_total)" ]; then
  echo -e "${RED}  X cannot reach mvno-api /actuator/prometheus - is mvno-api up on :8080?${NC}"; exit 1
fi
ok "mvno-api metrics reachable"

# =============================================================================
# Cell 1 - 2G -> 2G (2G SMSC direct; bridge must NOT be involved)
# =============================================================================
# Direction matches the manual guide's canonical 2G->2G (6a): MS2 sends, MS1
# (the only MS that logs receipts) receives.
section "Cell 1: 2G->2G  (15557778888 -> 15554443322, 2G SMSC direct)"
b_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b_25="${b_25:-0}"
b_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; b_52="${b_52:-0}"
BODY1="E2E 2G2G ${TS}"
python3 "${SCRIPT_DIR}/send_smpp_sms.py" --sender 15557778888 --recipient 15554443322 \
  --message "${BODY1}" >/dev/null
sleep 8
a_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a_25="${a_25:-0}"
a_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; a_52="${a_52:-0}"
RECEIPTS="$(podman exec mvno-2g-ms grep -cF "${BODY1}" /root/.osmocom/bb/sms.txt 2>/dev/null || true)"
if [ "$a_25" = "$b_25" ] && [ "$a_52" = "$b_52" ]; then
  ok "delivered via 2G SMSC; bridge counters unchanged (2g5g=$a_25,5g2g=$a_52)"
else
  bad "bridge counters moved unexpectedly (2g5g $b_25->$a_25, 5g2g $b_52->$a_52)"
fi
if [ "${RECEIPTS}" -ge 1 ]; then
  ok "MS1 handset receipt in sms.txt (${RECEIPTS}x '${BODY1}')"
else
  bad "no MS1 receipt for '${BODY1}' in /root/.osmocom/bb/sms.txt"
fi

# =============================================================================
# Cell 2 - 2G -> 5G (bridge poll of smsc.db -> SIP via Kamailio -> 5G terminal)
# =============================================================================
section "Cell 2: 2G->5G  (15554443322 -> 15551234567, smsc.db poll -> SIP relay)"
b_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b_25="${b_25:-0}"
BODY2="E2E 2G5G ${TS}"
start_recv ims_rx54 15551234567 10.89.0.54 45
sleep 4
python3 "${SCRIPT_DIR}/inject_smsc_row.py" 15554443322 15551234567 "${BODY2}" >/dev/null
sleep 10
a_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a_25="${a_25:-0}"
RX2="$(podman logs ims_rx54 2>&1 | grep -cF "${BODY2}" || true)"
if [ "$((a_25 - b_25))" -ge 1 ] && [ "${RX2}" -ge 1 ]; then
  ok "delivered 2G->5G via bridge+Kamailio (2g5g +$((a_25 - b_25))); terminal got '${BODY2}'"
else
  bad "2g5g $b_25->$a_25; terminal log: $(podman logs ims_rx54 2>&1 | tail -4 | tr '\n' ' ')"
fi
stop_ims ims_rx54

# =============================================================================
# Cell 3 - 5G -> 2G (IMS send -> bridge relay :5090 -> SMPP -> SMSC -> MS1)
# =============================================================================
section "Cell 3: 5G->2G  (15551234567 -> 15554443322, bridge relay -> SMPP)"
b_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; b_52="${b_52:-0}"
BODY3="E2E 5G2G ${TS}"
start_send ims_tx55 15551234567 15554443322 "${BODY3}" 10.89.0.55
sleep 12
a_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; a_52="${a_52:-0}"
MS1_HITS="$(podman exec mvno-2g-ms grep -cF "${BODY3}" /root/.osmocom/bb/sms.txt 2>/dev/null || true)"
if [ "$((a_52 - b_52))" -ge 1 ] && [ "${MS1_HITS}" -ge 1 ]; then
  ok "delivered 5G->2G via bridge+SMPP (5g2g +$((a_52 - b_52))); MS1 sms.txt has '${BODY3}'"
else
  bad "5g2g $b_52->$a_52; MS1 sms.txt hits=${MS1_HITS}: $(podman exec mvno-2g-ms cat /root/.osmocom/bb/sms.txt 2>/dev/null | tail -2 | tr '\n' ' ')"
fi

# =============================================================================
# Cell 4 - 5G -> 5G (Kamailio twin relay; bridge must stay untouched)
# =============================================================================
section "Cell 4: 5G->5G  (15551234567 -> 15557654321, Kamailio twin relay)"
b_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; b_25="${b_25:-0}"
b_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; b_52="${b_52:-0}"
BODY4="E2E 5G5G ${TS}"
start_recv ims_rx56 15557654321 10.89.0.56 90
sleep 4
start_send ims_tx55 15551234567 15557654321 "${BODY4}" 10.89.0.55
sleep 8
a_25="$(bridge_counter mvno_bridge_sms_2g_to_5g_total || true)"; a_25="${a_25:-0}"
a_52="$(bridge_counter mvno_bridge_sms_5g_to_2g_total || true)"; a_52="${a_52:-0}"
RX4="$(podman logs ims_rx56 2>&1 | grep -cF "${BODY4}" || true)"
if [ "${RX4}" -ge 1 ] && [ "$a_25" = "$b_25" ] && [ "$a_52" = "$b_52" ]; then
  ok "relayed 5G->5G via Kamailio; terminal got '${BODY4}'; bridge untouched (2g5g=$a_25,5g2g=$a_52)"
else
  bad "rx56 hits=${RX4}; 2g5g $b_25->$a_25, 5g2g $b_52->$a_52; log: $(podman logs ims_rx56 2>&1 | tail -4 | tr '\n' ' ')"
fi

# =============================================================================
# Cell 5 - AI-BLOCK (E2E-BLOCK marker -> mock allow:false -> 403 + counter)
# =============================================================================
section "Cell 5: AI-BLOCK  (E2E-BLOCK marker -> 403, counter++, no delivery)"
B_BLK="$(api_counter mvno_sms_blocked_total)"; B_BLK="${B_BLK:-0}"
BODY5="E2E-BLOCK 5G5G ${TS}"
start_send ims_tx55 15551234567 15557654321 "${BODY5}" 10.89.0.55
sleep 8
A_BLK="$(api_counter mvno_sms_blocked_total)"; A_BLK="${A_BLK:-0}"
SEND403="$(podman logs ims_tx55 2>&1 | grep -c '403' || true)"
RX_NO="$(podman logs ims_rx56 2>&1 | grep -cF "${BODY5}" || true)"
K_BLOCK="$(podman logs mvno-kamailio --since 2m 2>&1 | grep -c 'SMS BLOCKED BY MVNO INTERCEPTION CORE' || true)"
if [ "$A_BLK" -gt "$B_BLK" ] && [ "${SEND403}" -ge 1 ] && [ "${RX_NO}" -eq 0 ] && [ "${K_BLOCK}" -ge 1 ]; then
  ok "blocked by AI core (blocked $B_BLK->$A_BLK, sender saw 403, receiver untouched, kamailio logged block)"
else
  bad "blocked $B_BLK->$A_BLK; sender 403 hits=${SEND403}; rx56 marker hits=${RX_NO}; kamailio block lines=${K_BLOCK}"
fi
stop_ims ims_rx56

# =============================================================================
# Summary
# =============================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}==== E2E RUNBOOK: ALL CELLS PASS (${PASS} ok) ====${NC}"
  exit 0
else
  echo -e "${RED}==== E2E RUNBOOK: ${FAIL} FAILURE(S), ${PASS} ok ====${NC}"
  exit 1
fi
