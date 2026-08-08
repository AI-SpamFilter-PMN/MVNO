#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — ONE-COMMAND team bring-up for the MVNO core
#
# A fresh teammate machine (Ubuntu/Debian/Fedora/Arch) deploys with a single
# command; it installs missing host packages, loads SCTP, pulls the custom
# images from Docker Hub (or vendor/ tarballs), initialises the SQLite DBs,
# launches the 30+ service stack and self-heals common failures:
#
#   ./scripts/deploy.sh             full bring-up (pulls images from Docker Hub)
#   ./scripts/deploy.sh --offline   load vendor/ tarballs (air-gapped path)
#   ./scripts/deploy.sh --build     docker-compose.build.yml up --build
#   ./scripts/deploy.sh --check     read-only preflight, no changes
#   ./scripts/deploy.sh --no-install skip sudo package installation
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || { echo "ERROR: cannot cd to $PROJECT_DIR"; exit 1; }

PRECHECK=0; OFFLINE=0; BUILD=0; INSTALL=1
case "${1:-up}" in
  --check) PRECHECK=1 ;;
  --offline) OFFLINE=1 ;;
  --build) BUILD=1 ;;
  --no-install) INSTALL=0 ;;
  up) : ;;
  -h|--help)
    cat <<'EOF'
usage: ./scripts/deploy.sh [mode]

  (default)  full bring-up: install deps -> pull images -> init-db -> up ->
             wait for health -> self-heal, then exit 0/1
  --offline  load container images from vendor/ tarballs (pre-ran bootstrap.sh)
  --build    build custom images from source (docker-compose.build.yml)
  --check    read-only host preflight (no installs, no containers)
  --no-install  skip sudo package installation
EOF
    exit 0 ;;
  *) echo "unknown option: $1"; exit 2 ;;
esac

SUCCESSES=(); FAILURES=()
step() { echo ""; echo "=== $* ==="; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
fail() { echo "  ✗ $*"; FAILURES+=("$*"); }

# ---- 0. Runtime detection -----------------------------------------------------
RT=""
if command -v podman >/dev/null 2>&1; then RT="podman"
elif command -v docker >/dev/null 2>&1; then RT="docker"; fi
COMPOSE_CMD="${RT:-false} compose"
COMPOSE_LIST="${RT:-false} ps"

# ---- 1. Read-only preflight ----------------------------------------------------
if [ "$PRECHECK" -eq 1 ]; then
  bash "$SCRIPT_DIR/preflight.sh"; exit $?
fi

# ---- 2. Host package install --------------------------------------------------
if [ "$INSTALL" -eq 1 ]; then
  step "Host prerequisites"
  if [ -z "$RT" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "» installing podman + compose (apt)"; sudo apt-get update -qq && sudo apt-get install -y podman docker-compose-v2
    elif command -v dnf >/dev/null 2>&1; then
      echo "» installing podman + compose (dnf)"; sudo dnf install -y podman docker-compose-plugin
    elif command -v pacman >/dev/null 2>&1; then
      echo "» installing podman + compose (pacman)"; sudo pacman -Sy --noconfirm podman docker-compose
    else
      fail "no supported package manager — install podman + compose plugin manually"; exit 1
    fi
    RT="podman"
  else
    ok "container runtime: $RT"
  fi
  for tool in sqlite3 curl espeak-ng ffmpeg baresip tshark nc; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool present"
    else
      # tool name != package name for some tools; map per distro
      case "$tool:$(command -v apt-get >/dev/null 2>&1 && echo apt || { command -v dnf >/dev/null 2>&1 && echo dnf || echo pacman; })" in
        baresip:*)        pkg=baresip ;;
        tshark:apt*)      pkg=tshark ;;
        tshark:*)         pkg=wireshark-cli ;;
        nc:apt*)          pkg=netcat-openbsd ;;
        nc:dnf*)          pkg=nmap-ncat ;;
        nc:*)             pkg=openbsd-netcat ;;
        *)                pkg=$tool ;;
      esac
      echo "» installing $tool ($pkg)"
      if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y "$pkg"
      elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y "$pkg"
      elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm "$pkg"; fi
    fi
  done
else
  warn "--no-install: skipping sudo installs (assuming packages present)"
fi

# ---- 3. Kernel prerequisites --------------------------------------------------
step "Kernel prerequisites"
if [ -z "$RT" ]; then RT="podman"; fi   # compose refs below use RT
if sudo -n modprobe sctp >/dev/null 2>&1 || modprobe sctp >/dev/null 2>&1; then ok "sctp module available"; else warn "sctp missing (5G NGAP gNB<->AMF won't connect)"; fi
[ -c /dev/net/tun ] && ok "/dev/net/tun present" || warn "/dev/net/tun missing (5G user plane)"
[ -d /proc/net/sctp ] && ok "/proc/net/sctp up" || warn "/proc/net/sctp absent (verify sctp loaded)"

# ---- 4. Images ----------------------------------------------------------------------
step "Images"
if [ "$OFFLINE" -eq 1 ]; then
  if [ -d vendor/docker ]; then bash "$SCRIPT_DIR/load-offline.sh" && ok "vendored images loaded" || fail "load-offline.sh failed"
  else warn "vendor/docker absent — cannot continue offline"; BUILD=1; fi
elif [ "$BUILD" -eq 1 ]; then
  warn "will build custom images from source"
elif bash "$SCRIPT_DIR/pull-images.sh" >/dev/null 2>&1; then
  ok "all custom images pulled from Docker Hub"
else
  warn "pull-images.sh failed — falling back to source build"; BUILD=1
fi

# ---- 5. Databases -----------------------------------------------------------------------
step "Initialise subscriber databases"
if make init-db >/dev/null 2>&1; then ok "init-db"; else fail "make init-db"; fi

# ---- 6. Launch ---------------------------------------------------------------------------
step "Launching 31-service stack"
if [ "$BUILD" -eq 1 ]; then
  "$SCRIPT_DIR/up.sh" --build && ok "up.sh --build" || fail "up.sh --build"
else
  "$SCRIPT_DIR/up.sh" && ok "up.sh" || fail "up.sh"
fi

# ---- 7. Wait for health + self-heal ------------------------------------------------------
step "Health check & self-heal"
api_up() { curl -sf -m 2 http://localhost:8080/actuator/health >/dev/null 2>&1; }
restart_exited() {
  local exited
  exited=$($RT ps -aq -f status=exited 2>/dev/null)
  [ -n "$exited" ] && $RT restart $exited >/dev/null 2>&1 && ok "restarted exited containers"
}
heal=0
while [ "$heal" -lt 4 ]; do
  heal=$((heal+1))
  if api_up; then ok "API healthy (attempt ${heal})"; break; fi
  warn "API not ready (attempt ${heal}/4) — probing stack"
  if $RT ps -a 2>/dev/null | grep -qi 'exited'; then restart_exited; fi
  "$COMPOSE_CMD" up -d --remove-orphans >/dev/null 2>&1 || true
  sleep 6
done
if ! api_up; then fail "API never became healthy; see ONBOARDING.md Section 11"; fi

# ---- 8. Final health / summary --------------------------------------------------------
step "Health snapshot"
curl -s -m 3 http://localhost:8080/actuator/health | head -c 200; echo ""
echo "compose ps lines: $($COMPOSE_CMD ps 2>/dev/null | wc -l)"

echo ""
echo "=== DEPLOY SUMMARY ==="
for s in "${SUCCESSES[@]:-}"; do ok "$s"; done
if [ "${#FAILURES[@]}" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  ✗ $f"; done
  echo "RESULT: PARTIAL — troubleshoot per ONBOARDING.md Section 11"
  exit 1
else
  echo "RESULT: READY — run ./scripts/testing/live_demo.sh (13-check gate) to certify"
  exit 0
fi