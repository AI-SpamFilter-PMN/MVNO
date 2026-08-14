#!/usr/bin/env bash
# ==============================================================================
# pull-images.sh — Pull MVNO custom images from Docker Hub and retag to the bare
# local names docker-compose.yml expects (mvno-open5gs:2.8.0, ...).
#
# Use on a teammate machine that has internet but no local image cache:
#   ./scripts/pull-images.sh
#
# The compose file references bare `mvno-*` names (which resolve to
# localhost/mvno-* on Podman). This script pulls each image from the public
# Docker Hub namespace and re-tags it so `./scripts/up.sh` / `podman compose up`
# find them offline. Skips images that already exist locally.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

HUB_NAMESPACE="5attab007"

if command -v podman &>/dev/null; then
  RUNTIME="podman"
else
  RUNTIME="docker"
fi

IMAGES=(
  "mvno-kamailio:5.7.2"
  "mvno-2g-ms:1.0.0"
  "mvno-2g-core:1.0.0"
  "mvno-osmo-smsc:1.0.0"
  "mvno-ueransim:3.2.6"
  "mvno-open5gs:2.8.0"
  "mvno-open5gs-webui:2.8.0"
  "mvno-telecom-api:1.0.0"
  "mvno-asterisk:1.0.0"
  "mvno-baresip:1.1.0"
)

for img in "${IMAGES[@]}"; do
  if $RUNTIME image exists "$img" 2>/dev/null; then
    echo "  present  $img (skipped)"
    continue
  fi
  echo "  pulling  $img"
  $RUNTIME pull "$HUB_NAMESPACE/$img"
  $RUNTIME tag "$HUB_NAMESPACE/$img" "$img"
done

echo "Done — custom images ready for ./scripts/up.sh"