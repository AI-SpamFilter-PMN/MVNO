#!/usr/bin/env bash
# up.sh — Offline-first wrapper around podman compose
#
# Tries pre-loaded images first (fast, offline). Falls back to
# building from source if any custom images are missing.
#
# Usage:
#   ./scripts/up.sh              Start stack (offline-first)
#   ./scripts/up.sh --build      Force build from source
#   ./scripts/up.sh down         Stop stack (passthrough)
#   ./scripts/up.sh logs -f      Follow logs (passthrough)

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

# ─── Passthrough commands that need no build logic ─────
case "${1:-}" in
  down|logs|ps|stop|restart|config|create)
    exec $COMPOSE_CMD -f docker-compose.yml "$@"
    ;;
  --build)
    shift
    exec $COMPOSE_CMD -f docker-compose.yml -f docker-compose.build.yml up -d --build "$@"
    ;;
esac

# ─── Pre-flight: check custom images ───────────────────
MISSING=()
for img in "${CUSTOM_IMAGES[@]}"; do
  if ! podman image exists "$img" 2>/dev/null; then
    MISSING+=("$img")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Custom images not found: ${MISSING[*]}"
  echo "Building from source..."
  exec $COMPOSE_CMD -f docker-compose.yml -f docker-compose.build.yml up -d --build "$@"
fi

echo "All images present, starting offline..."
exec $COMPOSE_CMD -f docker-compose.yml up -d "$@"
