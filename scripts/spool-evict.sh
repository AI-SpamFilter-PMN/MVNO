#!/usr/bin/env bash
# ==============================================================================
# spool-evict.sh — MVNO Call-Recording Spool Retention / Eviction
# ==============================================================================
# Keeps state/spool/{pcaps,archived} within budget so live-call analysis (Tier-1
# live_tap + NativeVoskService) never grows without bound. The Java service and
# live_tap.sh never delete finished recordings themselves; this is the single
# eviction point (run manually, via cron, or the optional rootless systemd
# timer shown in docs/LIVE_DEMO.md S6).
#
# Policy (oldest-first, idempotent):
#   1. Files older than 7 days are removed first.
#   2. If a directory still exceeds the 100 MB cap, the oldest remaining
#      files are deleted until the cap is met.
#   3. Dry-run mode (-n) only reports what would be removed.
#
# Usage: ./scripts/spool-evict.sh [-n] [pcaps-dir] [archived-dir]
#   -n  dry-run (print what would be deleted, change nothing)
#
# Exit 0 on success (even if nothing to evict).
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

DRY_RUN=0
if [ "${1:-}" = "-n" ]; then DRY_RUN=1; shift; fi

SPOOL_DIR="${PROJECT_DIR}/state/spool"
PCAPS_DIR="${1:-${SPOOL_DIR}/pcaps}"
ARCHIVED_DIR="${2:-${SPOOL_DIR}/archived}"

MAX_AGE_SECONDS=$((7 * 24 * 3600))
MAX_BYTES=$((100 * 1024 * 1024))

evict() {
    local dir="$1"
    [ -d "$dir" ] || { echo "  skip: ${dir} (absent)"; return 0; }

    # Phase 1: age-based eviction
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ $DRY_RUN -eq 1 ]; then echo "  would-remove (age): ${f}"
        else rm -f "$f"; echo "  removed (age): ${f}"; fi
    done < <(find "$dir" -type f -mtime +7)

    # Phase 2: cap-based eviction (delete oldest first until under cap)
    local size
    size=$(du -sb "$dir" 2>/dev/null | cut -f1 || echo 0)
    if [ "${size:-0}" -gt "$MAX_BYTES" ]; then
        echo "  ${dir}: $(numfmt --to=iec-i "${size}" 2>/dev/null || echo "${size}") over 100 MiB cap — evicting oldest"
        while IFS= read -r f; do
            [ -n "$f" ] || break
            size=$(du -sb "$dir" 2>/dev/null | cut -f1 || echo 0)
            [ "${size:-0}" -le "$MAX_BYTES" ] && break
            if [ $DRY_RUN -eq 1 ]; then echo "  would-remove (cap): ${f}"
            else rm -f "$f"; echo "  removed (cap): ${f}"; fi
        done < <(find "$dir" -type f -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)
    fi
}

echo "== spool-evict: pcaps=${PCAPS_DIR} archived=${ARCHIVED_DIR} (max-age 7d, max 100 MiB, dry-run=$DRY_RUN)"
evict "$PCAPS_DIR"
evict "$ARCHIVED_DIR"

echo "== post-eviction sizes:"
du -sh "$PCAPS_DIR" "$ARCHIVED_DIR" 2>/dev/null || true
exit 0
