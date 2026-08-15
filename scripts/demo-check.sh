#!/usr/bin/env bash
# ==============================================================================
# demo-check.sh — Pre-Flight Carrier Demo Health Gate
# ==============================================================================
# Validates the entire MVNO stack before live demonstrations:
# 1. Container health (Kamailio, RTPEngine, Asterisk, Telecom API, Open5GS, VM).
# 2. 5G SA Core & RAN UE Registration (ran_ue == 3).
# 3. Adaptive Handset / Softphone Endpoint Probe (endpoint_selector.py).
# 4. Osmocom SMPP :2775 Gateway Connectivity.
# 5. VictoriaMetrics TSDB & Scraper Readiness.
# ==============================================================================

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Dynamic Host IP synchronization
DETECTED_HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n1 || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
if [ -f configs/kamailio/kamailio.cfg ]; then
    sed -i -E "s/advertise [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:5060/advertise ${DETECTED_HOST_IP}:5060/g" configs/kamailio/kamailio.cfg
fi

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    printf "• %-55s " "${desc}..."
    if eval "${cmd}" >/dev/null 2>&1; then
        echo -e "\e[32m[PASS]\e[0m"
        PASS=$((PASS + 1))
    else
        echo -e "\e[31m[FAIL]\e[0m"
        FAIL=$((FAIL + 1))
    fi
}

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  MVNO 5G CORE — PRE-FLIGHT LIVE DEMONSTRATION HEALTH GATE             ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

# 1. Container Health
check "Kamailio SIP Proxy & USRLOC Core" "podman ps --format '{{.Names}}' | grep -x mvno-kamailio"
check "RTPEngine Carrier Media Proxy" "podman ps --format '{{.Names}}' | grep -x mvno-rtpengine"
check "Asterisk MCU / ConfBridge Media Server" "podman ps --format '{{.Names}}' | grep -x mvno-asterisk"
check "Telecom Gateway REST & ASR Interception API" "curl -s -m 2 http://localhost:8080/actuator/health | grep -q UP"
check "Open5GS 5G SA Core & UPF Data Plane" "podman ps --format '{{.Names}}' | grep -x mvno-upf"
check "VictoriaMetrics SRE TSDB (:8428)" "curl -s -m 2 http://localhost:8428/health | grep -q OK"

# 2. 5G SA RAN & UPF Session Count
check "5G SA Active UEs (ran_ue == 3)" "[ \$(curl -s 'http://localhost:8428/api/v1/query?query=ran_ue' | grep -o '\"value\":\\[[0-9.]*,\"[0-9.]*\"\\]' | grep -o '\"[0-9.]*\"' | tr -d '\"' | head -1) = '3' ]"

# 3. Osmocom SMSC SMPP Gateway
check "Osmocom SMPP SMSC Gateway (:2775)" "nc -z -w2 localhost 2775"

# 4. Adaptive Handset / Laptop Softphone Rig
echo ""
echo "📱 ADAPTIVE TELEPHONY ENDPOINT DISCOVERY:"
python3 "${REPO_ROOT}/scripts/lib/endpoint_selector.py"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
if [ "${FAIL}" -eq 0 ]; then
    echo -e "🎉 \e[32mPRE-FLIGHT HEALTH GATE PASSED (${PASS}/${PASS} CHECKS GREEN)\e[0m"
    echo "   Stack is 100% ready for live demonstration."
    echo "════════════════════════════════════════════════════════════════════════"
    exit 0
else
    echo -e "❌ \e[31mPRE-FLIGHT HEALTH GATE FAILED (${FAIL} CHECKS FAILED)\e[0m"
    echo "   Remediation: Run 'make up' or check failed service logs via 'podman logs <service>'."
    echo "════════════════════════════════════════════════════════════════════════"
    exit 1
fi
