#!/usr/bin/env bash
# ==============================================================================
# up.sh — MVNO Core Container Stack Launch Script
# ==============================================================================
# Provides an offline-first execution wrapper around `podman compose` / `docker compose`.
#
# Execution Logic:
# 1. Checks if all custom pre-built container images exist in local Podman/Docker storage.
# 2. If present, launches the container stack instantly without internet access (`make up`).
# 3. If any custom images are missing, falls back to building from source (`docker-compose.build.yml`).
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || { echo "ERROR: could not cd to $PROJECT_DIR"; exit 1; }

COMPOSE_CMD="podman compose"
CUSTOM_IMAGES=(
  mvno-kamailio
  mvno-open5gs
  mvno-open5gs-webui
  mvno-ueransim
  mvno-osmo-smsc
  mvno-telecom-api
  mvno-vosk-worker
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
  if ! podman image exists "$img" 2>/dev/null; then
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

