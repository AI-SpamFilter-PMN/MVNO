#!/usr/bin/env bash
# ==============================================================================
# cleanup-state.sh — Orphaned SQLite Lock File Cleanup Utility
# ==============================================================================
# Removes stale SQLite WAL/shm sidecar files (*.db-wal, *.db-shm) that can
# linger after abrupt container shutdowns and confuse later startups.
#
# Safety Model:
# 1. Every state subdirectory is mapped to its owning container.
# 2. If the owning container is currently RUNNING, its -wal/-shm files are
#    LIVE database state and are NEVER touched (skipped with a warning).
# 3. Only files whose owning container is absent or stopped are deleted.
# 4. -n / --dry-run prints what would be removed without deleting anything.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || { echo "ERROR: could not cd to $PROJECT_DIR"; exit 1; }

DRY_RUN=0
if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

# State directory -> owning container name map
declare -A OWNERS=(
    [state/hlr]="mvno-osmo-hlr"
    [state/kamailio]="mvno-kamailio"
    [state/grafana]="mvno-grafana"
)

is_container_running() {
    podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

removed=0
skipped=0

for dir in "${!OWNERS[@]}"; do
    [[ -d "$dir" ]] || continue
    container="${OWNERS[$dir]}"
    live=0
    if is_container_running "$container"; then
        live=1
    fi
    while IFS= read -r -d '' f; do
        if [[ $live -eq 1 ]]; then
            echo "SKIP (live): $container is running -> keeping $f"
            skipped=$((skipped + 1))
        else
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "DRY-RUN: would remove $f ($container not running)"
            else
                rm -f "$f"
                echo "REMOVED: $f ($container not running)"
                removed=$((removed + 1))
            fi
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.db-wal' -o -name '*.db-shm' \) -print0)
done

echo "----------------------------------------"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "cleanup-state.sh (dry-run): $skipped live files kept, $removed would be removed"
else
    echo "cleanup-state.sh: $skipped live files kept, $removed stale files removed"
fi
exit 0
