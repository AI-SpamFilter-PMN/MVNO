#!/usr/bin/env bash
# ==============================================================================
# clone.sh — Local Neon mirror (READ-ONLY on production, writes go local only)
# ==============================================================================
# Clones the production Neon DB (schema + data) into the local `mvno-neon-local`
# Postgres container so the flag-for-review pipeline can be developed and
# verified locally with zero risk to the live DB.
#
# SAFETY CONTRACT:
#   * Production (NEON_DB_URL) is touched ONLY by pg_dump — a read-only tool.
#     No INSERT/UPDATE/DELETE/DDL is ever issued against it from this repo.
#   * All pipeline writes target the LOCAL clone (NEON_DB_LOCAL_URL).
#   * Every production-facing SQL change ships in docs/DB-Changes.md for
#     human review before anything is applied on Neon.
#
# Usage:
#   bash scripts/neon/clone.sh            # full schema+data mirror
#   bash scripts/neon/clone.sh --schema-only
#   bash scripts/neon/clone.sh --restore-only   # skip dump; restore local dump
#
# Env: NEON_DB_URL (production, from .env) and NEON_DB_LOCAL_URL (default
# postgresql://mvno:mvno@127.0.0.1:5433/neondb).
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
[ -f .env ] && set -a && source .env && set +a

MODE="${1:-full}"
LOCAL_URL="${NEON_DB_LOCAL_URL:-postgresql://mvno:mvno@127.0.0.1:5433/neondb}"
DUMP_DIR="state/neon-dumps"
DUMP_FILE="${DUMP_DIR}/neon-clone.sql"
mkdir -p "${DUMP_DIR}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

# --- Production dump (read-only; skip if --restore-only) ----------------------
if [ "${MODE}" != "--restore-only" ]; then
    if [ -z "${NEON_DB_URL:-}" ]; then
        echo -e "${RED}FATAL: NEON_DB_URL not set (add to .env — git-ignored).${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}→ pg_dump production Neon (READ-ONLY)…${NC}"
    DUMPSQL=(pg_dump --no-owner --no-privileges --dbname="${NEON_DB_URL}")
    [ "${MODE}" = "full" ] || DUMPSQL+=(--schema-only)
    # Run pg_dump from a disposable postgres client container (host has none);
    # stdout is piped straight to the host dump file — no inner shell, so the
    # URL's ?/&/ quotes need no escaping.
    podman run --rm docker.io/library/postgres:18-alpine \
        "${DUMPSQL[@]}" > "${DUMP_FILE}" 2>/tmp/neon-pgdump.err \
        || { echo -e "${RED}FATAL: pg_dump failed: $(tail -3 /tmp/neon-pgdump.err | tr '\n' ' ')${NC}" >&2; exit 1; }
    echo -e "${GREEN}✓ dumped: ${DUMP_FILE} ($(wc -l < "${DUMP_FILE}" | tr -d ' ') lines)${NC}"
fi

# --- Restore into the local clone --------------------------------------------
echo -e "${YELLOW}→ restore into local clone (${LOCAL_URL%%@*}@…)…${NC}"
# Drop + recreate the local schema so a re-clone is always a clean mirror.
podman exec mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=0 -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
podman exec -i mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=0 \
    < "${DUMP_FILE}" >/dev/null 2>&1 \
    || { echo -e "${RED}FATAL: restore failed (see above)${NC}" >&2; exit 1; }

# --- Verify mirror ------------------------------------------------------------
echo -e "${GREEN}✓ restored. Tables in local clone:${NC}"
podman exec mvno-neon-local psql -U mvno -d neondb -c \
    "\dt" 2>/dev/null | awk 'NR>2 && $1!="" {print "  - " $3}' | head -20
echo -e "${GREEN}✓ local mirror ready. Pipeline writes go here ONLY.${NC}"
