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
            docker_wrapper() { sg docker -c "docker $*"; }
            DOCKER_CMD="docker_wrapper"
            export -f docker_wrapper 2>/dev/null || true
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

# ─── --verify-tags: drift gate (Goal 1) ─────────────────────────────────────
# Compares the image tags embedded in vendor/docker/*.tar against the image: pins
# in docker-compose.yml. Exits non-zero if any compose pin has no matching tarball,
# so silent version-skew (vendored :latest but compose wants :5.7.2) fails LOUDLY.
# Usage: ./scripts/load-offline.sh --verify-tags
if [ "${1:-}" = "--verify-tags" ]; then
    echo "=== Verifying vendored tags vs docker-compose.yml pins ==="
    if [ ! -d "$VENDOR_DIR/docker" ]; then
        echo "  ✗ vendor/docker/ not found — run bootstrap.sh first"; exit 1
    fi
    # Collect the image tags present in vendored tarballs.
    # `podman/docker load` prints "Loaded image: <repo:tag>"; we mirror that by
    # inspecting each tar's manifest via the engine if available, else fall back to
    # the tarball filename convention used by bootstrap.sh SAVE_IMAGES keys.
    declare -a VENDOR_TAGS=()
    for tar in "$VENDOR_DIR/docker"/*.tar; do
        [ -f "$tar" ] || continue
        # Inspect the tar for repository tags (works for docker save format).
        tags=$($DOCKER_CMD load -i "$tar" 2>/dev/null | grep -oE 'Loaded image[^:]*: [^ ]+' | sed -E 's/Loaded image[^:]*: //')
        if [ -z "$tags" ]; then
            # Fallback: skip (cannot determine tag) — recorded as unknown.
            VENDOR_TAGS+=("UNKNOWN:$(basename "$tar" .tar)")
        else
            while IFS= read -r t; do [ -n "$t" ] && VENDOR_TAGS+=("$t"); done <<< "$tags"
        fi
    done
    DRIFT=0
    while IFS= read -r pin; do
        [ -n "$pin" ] || continue
        found=0
        for vt in "${VENDOR_TAGS[@]}"; do
            if [ "$vt" = "$pin" ]; then found=1; break; fi
        done
        if [ "$found" -eq 0 ]; then
            echo "  ✗ MISSING in vendor: $pin"
            DRIFT=$((DRIFT+1))
        else
            echo "  ✓ present: $pin"
        fi
    done < <(grep -oE 'image: .*' "$PROJECT_DIR/docker-compose.yml" | sed -E 's/image: *"?([^"]+)"?/\1/' | sort -u)
    echo "----------------------------------------------"
    if [ "$DRIFT" -ne 0 ]; then
        echo "RESULT: ✗ $DRIFT compose pin(s) have no matching vendored tarball (version-skew)."
        echo "Re-run ./scripts/bootstrap.sh (online) to re-vendor with the exact tags."
        exit 1
    fi
    echo "RESULT: ✓ All compose image pins have matching vendored tarballs (no drift)."
    exit 0
fi

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
