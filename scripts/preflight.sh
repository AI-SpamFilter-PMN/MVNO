#!/usr/bin/env bash
# ==============================================================================
# preflight.sh — MVNO Core Host-Environment Pre-flight Checks
# ==============================================================================
# Verifies the host can run the full MVNO stack (rootless Podman + 5G SA + 2G).
# Run BEFORE `make up`. Exits non-zero on a hard blocker; warns on soft issues.
#
# Supported environment (see docs/ENVIRONMENT_MATRIX.md):
#   - amd64 Linux + rootless Podman (verified)
#   - macOS / Windows / Docker Desktop / arm64 = NOT supported for the full stack
#     (tun + SCTP + multicast require a Linux kernel; arm64 needs a source rebuild).
#
# Usage: ./scripts/preflight.sh [-q]
#   -q  quiet (only print failures)
# ==============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}" || { echo "ERROR: cannot cd to ${PROJECT_DIR}"; exit 1; }

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

ok()   { [ $QUIET -eq 0 ] && echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
fail() { echo "  ✗ $*"; HARD_FAIL=1; }

HARD_FAIL=0
WARN_FAIL=0

echo "╔══════════════════════════════════════════════╗"
echo "║   MVNO Core Pre-flight Environment Check     ║"
echo "╚══════════════════════════════════════════════╝"

# ─── 1. Architecture & OS ────────────────────────────────────────────────────
ARCH="$(uname -m)"
OS_ID=""
[ -f /etc/os-release ] && . /etc/os-release && OS_ID="${ID:-unknown}"
case "${ARCH}" in
  x86_64) ok "Architecture: amd64 (${ARCH})" ;;
  aarch64|arm64) warn "Architecture: arm64 — requires full source rebuild of custom images (untested)"; WARN_FAIL=1 ;;
  *) warn "Architecture: ${ARCH} — unsupported"; WARN_FAIL=1 ;;
esac
if [ "$(uname -s)" = "Darwin" ]; then
  warn "macOS host — vendor-only path; the full stack (tun+SCTP) cannot run here"
  WARN_FAIL=1
else
  ok "OS: Linux (${OS_ID})"
fi

# ─── 2. Container runtime + compose plugin ───────────────────────────────────
RT=""
if command -v podman >/dev/null 2>&1; then
  RT="podman"
  if podman compose version >/dev/null 2>&1; then ok "podman compose plugin present"
  else fail "podman found but 'podman compose' plugin missing (install docker-compose)"; fi
elif command -v docker >/dev/null 2>&1; then
  RT="docker"
  if docker compose version >/dev/null 2>&1; then ok "docker compose plugin present"
  else fail "docker found but 'docker compose' plugin missing"; fi
else
  fail "No container runtime (install podman + compose plugin or docker + compose)"
fi

# ─── 3. Host CLI tools ───────────────────────────────────────────────────────
for tool in sqlite3 nc curl python3; do
  if command -v "${tool}" >/dev/null 2>&1; then ok "${tool} present"
  else fail "${tool} not found (required by make init-db / vty.sh / live_demo)"; fi
done

# ─── 3b. Demo toolchain (live-demo S1–S10: calls, ASR, pcap, audio) ─────────
DEMO_TOOLS="tshark ffprobe aplay espeak-ng xxd ffmpeg md5sum"
DEMO_MISSING=""
for tool in ${DEMO_TOOLS}; do
  if command -v "${tool}" >/dev/null 2>&1; then ok "${tool} present (live-demo)"
  else DEMO_MISSING="${DEMO_MISSING} ${tool}"
       warn "${tool} not found — live-demo speech/pcap/audio steps will fail" ; fi
done
[ -z "${DEMO_MISSING}" ] || WARN_FAIL=1

# ─── 4. /dev/net/tun (5G UPF + UERANSIM) ─────────────────────────────────────
if [ -c /dev/net/tun ]; then ok "/dev/net/tun present (5G user-plane)"
else fail "/dev/net/tun missing — 5G SA core cannot run (Linux only)"; fi

# ─── 5. SCTP kernel module (AMF↔gNB NGAP, osmo-stp M3UA) ──────────────────────
if [ -d /proc/net/sctp ] || modprobe -n sctp >/dev/null 2>&1; then
  ok "SCTP available (/proc/net/sctp or module loadable)"
else
  warn "SCTP not available — 5G NGAP and 2G M3UA will fail. Try: sudo modprobe sctp"
  WARN_FAIL=1
fi

# ─── 6. Multicast (2G virtual-Um osmocom-bb virtphy) ─────────────────────────
if [ "${RT}" = "podman" ] || [ "${RT}" = "docker" ]; then
  # Verify the bridge/interface actually carries the MULTICAST flag — the 2G
  # virtual-Um uses 239.193.23.1:4729 and cloud/VM bridges often disable it.
  MCAST_IF="$(ip -o link show 2>/dev/null | grep -iE 'MULTICAST' | head -1 | sed -E 's/^[0-9]+: ([^:]+):.*/\1/')"
  if [ -n "${MCAST_IF}" ]; then
    ok "Multicast: interface ${MCAST_IF} carries MULTICAST flag (2G virtual-Um uses 239.193.23.1:4729)"
  elif ip -o link >/dev/null 2>&1; then
    warn "No interface with MULTICAST flag found — 2G virtual-Um may fail on cloud/VM bridges"
    warn "  Try: sudo ip link set <bridge> multicast on"
    WARN_FAIL=1
  else
    warn "Cannot query host links — verify multicast is enabled for the 2G virtual-Um path"
    WARN_FAIL=1
  fi
fi

# ─── 6b. UFW firewall (Ubuntu) — SIP/media port rules ────────────────────────
# Ubuntu's default UFW silently DROPS the phone's RTP media (UDP 10000-20000)
# while SIP (5060) still passes — calls ring but carry no audio. This is the
# single most common Ubuntu-only landmine, so warn loudly when UFW is active
# without the media range allowed.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qE 'Status: active'; then
  if ufw status 2>/dev/null | grep -qE '10000:20000.*(udp|ALLOW)'; then
    ok "UFW active and allows UDP 10000:20000 (phone RTP media)"
  else
    warn "UFW is ACTIVE but UDP 10000:20000 is not allowed — phone call media will be silently dropped."
    warn "  Run: sudo ufw allow 5060/udp && sudo ufw allow 10000:20000/udp"
    WARN_FAIL=1
  fi
else
  ok "UFW not active (or not installed) — no firewall port blocking expected"
fi

# ─── 7. Host UDP 5060 conflict (canonical Kamailio host port = 5060) ─────────
# Kamailio is published directly on the standard host SIP port 5060. Its own
# rootless-port bind on 5060 is EXPECTED and must not be mistaken for a conflict
# (an external Asterisk/second SIP stack on 5060 is the real problem). So we only
# warn when 5060 is held by something OTHER than the mvno-kamailio container's
# published mapping.
KAMAILIO_5060="$(podman port mvno-kamailio 2>/dev/null | grep -E ':5060' | head -1)"
if [ -n "${KAMAILIO_5060:-}" ]; then
  ok "Host UDP 5060 bound by mvno-kamailio (expected, canonical port)"
elif command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | grep -qE ':5060[[:space:]]'; then
  warn "Host UDP 5060 is occupied by a process OTHER than mvno-kamailio (e.g. a local Asterisk or second SIP stack)."
  warn "  Kamailio needs host UDP 5060 (canonical). Stop the other listener, or override the port."
  WARN_FAIL=1
else
  ok "Host UDP 5060 free (canonical Kamailio host port = 5060)"
fi

# ─── 8. Compose config + image-tag drift ─────────────────────────────────────
if [ -n "${RT}" ]; then
  if ${RT} compose config -q >/dev/null 2>&1; then ok "docker-compose.yml config valid"
  else fail "docker-compose.yml config invalid (run: ${RT} compose config)"; fi
  DRIFT=0
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if [ "${RT}" = "podman" ]; then podman image exists "${tag}" >/dev/null 2>&1 || DRIFT=$((DRIFT+1))
    else docker image inspect "${tag}" >/dev/null 2>&1 || DRIFT=$((DRIFT+1)); fi
  done < <(grep -oE 'image: .*' docker-compose.yml | sed -E 's/image: *"?([^"]+)"?/\1/' | sort -u)
  if [ "${DRIFT}" -eq 0 ]; then ok "All compose image pins present locally (no version-skew)"
  else warn "${DRIFT} compose image pin(s) not in local cache — run bootstrap.sh or load-offline.sh"; WARN_FAIL=1; fi
fi

echo "----------------------------------------------"
if [ "${HARD_FAIL}" -ne 0 ]; then
  echo "RESULT: ✗ HARD FAIL — fix the ✗ items above before 'make up'"
  exit 1
fi
if [ "${WARN_FAIL}" -ne 0 ]; then
  echo "RESULT: ! WARN — stack may come up but some features may be limited; review the ! items"
  exit 0
fi
echo "RESULT: ✓ ALL CLEAR — ready for 'make up'"
exit 0