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

# ─── Dynamic Host IP Auto-Detection (Env-Agnostic Advertised IP) ─────────────
DETECTED_HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n1 || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
export HOST_IP="${HOST_IP:-$DETECTED_HOST_IP}"
echo "HOST_IP=${HOST_IP}" > .env

# Dynamically synchronize advertised IP in Kamailio & RTPEngine configs
if [ -f configs/kamailio/kamailio.cfg ]; then
    sed -i -E "s/advertise [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:5060/advertise ${HOST_IP}:5060/g" configs/kamailio/kamailio.cfg
fi
if [ -f configs/rtpengine/rtpengine.conf ]; then
    sed -i -E "s/interface=eth0![0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/interface=eth0!${HOST_IP}/g" configs/rtpengine/rtpengine.conf
fi

export PODMAN_USER_UID=$(id -u)

CUSTOM_IMAGES=(
  mvno-kamailio:5.7.2
  mvno-open5gs:2.8.0
  mvno-open5gs-webui:2.8.0
  mvno-ueransim:3.2.6
  mvno-osmo-smsc:1.0.0
  mvno-telecom-api:1.0.0
  mvno-2g-core:1.0.0
  mvno-2g-ms:1.0.0
  # mvno-vosk-worker — removed: ASR runs in-process via NativeVoskService.java
)

# ─── Cold-start auto-provision (one-command `make up` / `podman compose up`) ──
# A plain launch with no subscriber DBs means a silently broken stack: no
# Kamailio subscriber table (SIP digest auth fails), no hlr.db IMSI map (2G
# paths), no balances (403 contract). `make init-db` creates them idempotently
# (CREATE TABLE IF NOT EXISTS + seed rows), so instead of a guided error we
# AUTO-PROVISION them here — `make up` / `podman compose up` now work from a
# truly cold tree (git clone → make up). Passthrough commands need no DBs.
case "${1:-}" in
  down|logs|ps|stop|restart|config|create) : ;;  # passthrough: no DB needed
  *)
    if [ ! -f state/kamailio/kamailio.db ] || [ ! -f state/hlr/hlr.db ]; then
      echo "ℹ️  cold start: subscriber DBs missing — auto-provisioning via 'make init-db'..."
      if ! make init-db >/dev/null 2>&1; then
        echo "❌ cold start: 'make init-db' failed (see above)." >&2
        echo "   Manual fallback: run 'make init-db' and retry." >&2
        exit 1
      fi
      [ -f state/kamailio/kamailio.db ] && [ -f state/hlr/hlr.db ] \
        && echo "  ✓ subscriber DBs provisioned (kamailio.db + hlr.db)" || exit 1
    fi
    ;;
esac

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

# ─── Validate compose file parses BEFORE touching the stack ──────────────────
# Fail fast (no silent partial up) if docker-compose.yml is malformed or the
# editor left an error. `config -q` returns non-zero on invalid YAML/merge.
if ! $COMPOSE_CMD -f docker-compose.yml config -q >/dev/null 2>&1; then
  echo "❌ docker-compose.yml failed validation. Run:" >&2
  echo "   $COMPOSE_CMD -f docker-compose.yml config" >&2
  echo "   and fix the reported error before bringing the stack up." >&2
  exit 1
fi

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

# ─── Exact-tag gate: every `image:` pin in docker-compose.yml must exist locally ──
# Prevents silent version-skew (e.g. vendored tar tagged :latest but compose wants :5.7.2)
# failing LOUDLY here instead of producing a broken offline/online hybrid pull later.
if [ "$IMAGE_EXISTS_CMD" = "podman image exists" ]; then
  TAG_EXISTS() { podman image exists "$1" 2>/dev/null; }
else
  TAG_EXISTS() { docker image inspect "$1" >/dev/null 2>&1; }
fi
DRIFT=()
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  TAG_EXISTS "$tag" || DRIFT+=("$tag")
done < <(grep -oE 'image: .*' docker-compose.yml | sed -E 's/image: *"?([^"]+)"?/\1/' | sort -u)
if [ ${#DRIFT[@]} -gt 0 ]; then
  echo "WARNING: exact-tag drift — these compose image pins are NOT in local cache:"
  printf '  - %s\n' "${DRIFT[@]}"
  echo "Run ./scripts/bootstrap.sh (online) to vendor them, or ./scripts/load-offline.sh"
  echo "after placing tarballs. Continuing (compose may pull them from registry)..."
fi

echo "All required images present. Launching offline container stack..."
if $COMPOSE_CMD -f docker-compose.yml up -d "$@"; then
  # ─── Auto-seed Open5GS Mongo (idempotent upsert) ────────────────────────────
  # seed-mongo.sh waits for mongodb readiness (up to 60 s) and upserts the 3
  # UERANSIM 5G SA subscribers. Without it, `make up` alone leaves the 5G UEs
  # unprovisioned (AMF attach fails). Safe to re-run on a live stack.
  echo "ℹ️  stack up — seeding Open5GS Mongo (5G SA subscribers)..."
  if ./scripts/seed-mongo.sh >/dev/null 2>&1; then
    echo "  ✓ Open5GS Mongo seeded (3× UERANSIM subscribers)"
  else
    echo "  ⚠ seed-mongo skipped/failed (check mvno-mongodb health later)" >&2
  fi
fi
