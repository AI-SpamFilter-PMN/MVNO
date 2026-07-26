#!/usr/bin/env bash
# ==============================================================================
# up.sh — MVNO Core Container Stack Launch Script
# ==============================================================================
# Provides an offline-first execution wrapper around `podman compose` / `docker compose`.
#
# Execution Logic:
# 1. Auto-detects container runtime (Podman or Docker with Compose plugin).
# 2. Checks if all custom pre-built container images exist in local storage.
# 3. If present, launches the container stack instantly without internet access (`make up`).
# 4. If any custom images are missing, falls back to building from source (`docker-compose.build.yml`).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || { echo "ERROR: could not cd to $PROJECT_DIR"; exit 1; }

# Auto-detect container runtime (supports both Podman and Docker)
detect_runtime() {
    if command -v podman &>/dev/null && podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
        IMAGE_EXISTS_CMD="podman image exists"
    elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        IMAGE_EXISTS_CMD="docker image inspect"
    else
        echo "ERROR: No container runtime found (podman or docker with compose plugin)"
        exit 1
    fi
}

detect_runtime

CUSTOM_IMAGES=(
  mvno-kamailio
  mvno-open5gs
  mvno-open5gs-webui
  mvno-ueransim
  mvno-osmo-smsc
  mvno-telecom-api
  # mvno-vosk-worker — removed: ASR runs in-process via NativeVoskService.java
)

# ─── Passthrough commands that need no build logic (down, logs, ps, stop, etc.) ─────
case "${1:-}" in
  down|logs|ps|stop|restart|config|create)
    exec $COMPOSE_CMD -f docker-compose.yml "$@"
    ;;
  --build)
    shift
    exec $COMPOSE_CMD -f docker-compose.yml -f docker-compose.build.yml up -d --build "$@"
    ;;
esac

# ─── Pre-flight: check if local custom images are pre-loaded ───────────────────
MISSING=()
for img in "${CUSTOM_IMAGES[@]}"; do
  if ! $IMAGE_EXISTS_CMD "$img" &>/dev/null; then
    MISSING+=("$img")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Custom images not found in local cache: ${MISSING[*]}"
  echo "Falling back to building from source..."
  exec $COMPOSE_CMD -f docker-compose.yml -f docker-compose.build.yml up -d --build "$@"
fi

echo "All required images present. Launching offline container stack..."
exec $COMPOSE_CMD -f docker-compose.yml up -d "$@"
