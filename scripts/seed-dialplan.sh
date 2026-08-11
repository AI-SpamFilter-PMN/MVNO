#!/usr/bin/env bash
# ==============================================================================
# MVNO Cellular Core — Kamailio Number-Normalization (dialplan dpid=4) Seeder
# ==============================================================================
# Recreates (deterministically, idempotently) the `dialplan` table in the
# Kamailio SQLite DB with the MVNO E.164/national → bare-MSISDN rules.
#
# WHY: Android softphones (Linphone, MizuDroid) dial +20/00-prefixed numbers,
# but usrloc/auth_db keep AoRs as bare 15XXXXXXXXX MSISDNs. These rules rewrite
# the R-URI user by default (dp_translate("4") in route[NORMALIZE], see
# configs/kamailio/kamailio.cfg) so both formats reach the same registered AoR.
#
# SAFE / IDEMPOTENT:
#   * Deletes ONLY dpid=4 rows, then re-inserts them, in a single transaction —
#     other dialplans (any future dpid) are left untouched.
#   * Re-runnable anytime; a fresh clone can provision the table from scratch.
#
# USAGE:
#   bash scripts/seed-dialplan.sh                # seed state/kamailio/kamailio.db
#   KAMAILIO_DB=/tmp/copy.db bash scripts/seed-dialplan.sh   # seed a copy (test)
#
# The DB is bind-mounted into the running kamailio container at
# /etc/kamailio/db (see docker-compose.yml), so host-side writes are picked up
# by the live process during its next RE-INVITE/INVITE lookup. Invoke this
# script (or restart kamailio / run `kamctl reload dialplan`) after changing it.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KAMAILIO_DB="${KAMAILIO_DB:-${SCRIPT_DIR}/../state/kamailio/kamailio.db}"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[-] sqlite3 CLI not found on PATH; cannot seed dialplan." >&2
    exit 1
fi

if [ ! -f "${KAMAILIO_DB}" ]; then
    echo "[-] Kamailio DB not found: ${KAMAILIO_DB}" >&2
    echo "    Expected the running stack's bind-mount (state/kamailio/kamailio.db)." >&2
    exit 1
fi

# --- dpid=4: E.164/national -> bare 15XXXXXXXXX ------------------------------
# pr order matters (first match wins). match_op=1 = POSIX regex.
#   1. +/00 country prefix (Egypt +20, or bare + with 10 national digits)
#   2. leading 00 international access
#   3. already-normalized 15X (idempotent passthrough)
#   4. safety identity for bare 15XXXXXXXXX (never alter what a desktop dials)
# repl_exp uses \1..\2 backreferences from match_exp capture groups.
sqlite3 "${KAMAILIO_DB}" <<'SQL'
BEGIN;
DELETE FROM dialplan WHERE dpid = 4;

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 1, 1, '^\+(20)?([5-9][0-9]{9})$',  0, '^\+(20)?([5-9][0-9]{9})$',  '1\2', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 2, 1, '^(00)2?([5-9][0-9]{9})$',   0, '^(00)2?([5-9][0-9]{9})$',   '1\2', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 3, 1, '^1([5-9][0-9]{9})$',        0, '^1([5-9][0-9]{9})$',        '1\1', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 4, 1, '^15[0-9]{9}$',              0, '',                          '\0',  '', 0);
COMMIT;
SQL

echo "[+] Seeded dpid=4 dialplan rules into ${KAMAILIO_DB}:"
sqlite3 -header -column "${KAMAILIO_DB}" \
  "SELECT pr, match_exp AS 'match', match_op AS 'op', repl_exp AS 'repl' FROM dialplan WHERE dpid=4 ORDER BY pr;"
echo "[+] Done. ${KAMAILIO_DB} has $(sqlite3 "${KAMAILIO_DB}" "SELECT COUNT(*) FROM dialplan WHERE dpid=4;") dpid=4 rule(s)."