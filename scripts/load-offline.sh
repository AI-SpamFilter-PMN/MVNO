#!/usr/bin/env bash
# load-offline.sh — Run on air-gapped machine to load all vendored artifacts
#
# Loads Docker/Podman images from tarballs saved by bootstrap.sh,
# verifies checksums, and prints a readiness summary.
#
# Usage:  ./scripts/load-offline.sh
# Prereq: vendor/ directory populated by bootstrap.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENDOR_DIR="$PROJECT_DIR/vendor"

SUCCESSES=()
FAILURES=()

try_log() {
    local label="$1" cmd="$2"
    local logfile="$VENDOR_DIR/logs/${label//\//_}.log"
    mkdir -p "$VENDOR_DIR/logs"
    echo ""
    echo "=== $label ==="
    if eval "$cmd" >> "$logfile" 2>&1; then
        echo "  ✓ $label"
        SUCCESSES+=("$label")
    else
        echo "  ✗ $label (see $logfile)"
        FAILURES+=("$label")
    fi
}

detect_runtime() {
    if command -v podman &>/dev/null; then
        DOCKER_CMD="podman"
        echo "Runtime: podman"
    elif command -v docker &>/dev/null; then
        if docker info &>/dev/null 2>&1; then
            DOCKER_CMD="docker"
        elif sg docker -c "docker info" &>/dev/null 2>&1; then
            docker_cmd() { sg docker -c "docker $*"; }
            DOCKER_CMD="docker_cmd"
        else
            echo "ERROR: Docker daemon not accessible. Try: newgrp docker"
            exit 1
        fi
        echo "Runtime: docker"
    else
        echo "ERROR: No container runtime found (docker or podman). Install one first."
        exit 1
    fi
}

echo "╔══════════════════════════════════════════════╗"
echo "║   MVNO Offline Loader                        ║"
echo "╚══════════════════════════════════════════════╝"

detect_runtime

if [ ! -d "$VENDOR_DIR/docker" ]; then
    echo "ERROR: $VENDOR_DIR/docker/ not found."
    echo "Run bootstrap.sh first on an internet-connected machine, then copy vendor/ here."
    exit 1
fi

# ─── Verify checksums ──────────────────────────────────
echo ""
echo "=== Verifying checksums ==="
if [ -f "$VENDOR_DIR/checksums/sha256sums.txt" ]; then
    if (cd "$PROJECT_DIR" && sha256sum -c "$VENDOR_DIR/checksums/sha256sums.txt" 2>/dev/null); then
        echo "  ✓ All checksums match"
    else
        echo "  [WARN] Some files have changed or are corrupt" | tee -a "$VENDOR_DIR/logs/checksum_error.log"
    fi
else
    echo "  [WARN] No checksums file found (vendor/checksums/sha256sums.txt)"
fi

# ─── Load Docker images ────────────────────────────────
echo ""
echo "=== Loading images ==="
loaded=0
skipped=0
for tar in "$VENDOR_DIR/docker"/*.tar; do
    [ -f "$tar" ] || continue
    name=$(basename "$tar" .tar)
    try_log "load:$name" "$DOCKER_CMD load -i '$tar'"
done

# ─── Summary ────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SUMMARY                                      ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Images loaded: ${#SUCCESSES[@]}"
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "  FAILED:       ${#FAILURES[@]}"
    for f in "${FAILURES[@]}"; do echo "    ✗ $f"; done
    echo ""
    echo "  Check logs: $VENDOR_DIR/logs/"
    exit 1
fi

echo ""
echo "  All images loaded successfully."
echo ""
echo "  Start the stack (offline-first, no build needed):"
echo "    docker compose -f $PROJECT_DIR/docker-compose.yml up -d"
echo ""
echo "  Or with podman (Docker Compose Plugin):"
echo "    systemctl --user enable --now podman.socket"
echo "    podman compose -f $PROJECT_DIR/docker-compose.yml up -d"
echo ""
echo "  To build from source (needs internet):"
echo "    podman compose -f $PROJECT_DIR/docker-compose.yml \\"
echo "                  -f $PROJECT_DIR/docker-compose.build.yml up -d --build"
