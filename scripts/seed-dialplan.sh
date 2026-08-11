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

# --- dpid=4: E.164/national/international -> bare 15XXXXXXXXX ---------------
# pr order matters (first match wins). match_op=1 = POSIX regex.
# Canonical stored AoR is the 11-digit national mobile WITHOUT the leading 0
# e.g. 0155...000 -> 155...000 (the '1' IS retained -- it is part of the AoR).
# A real softphone/NEON record dials one of:
#   1. E.164 strict  +2015559998888 ('+20' + 11-digit 1...)     -> drop '+20'
#   2. Legacy +20-no-1 (Linphone DIALS THIS) +205559998888      -> prepend the
#      omitted national '1' (10-digit 55... is the 1-less MSISDN)
#   3. '+'-national (US-style) +15559998888 and bare 15559998888 -> drop '+'/identity
#   4. National      015559998888 ('0' + 11-digit 1...)         -> drop leading '0'
#   5. International 00[20]15559998888 / 0015559998888           -> drop '00[20]'
# A caller who dials an arbitrary foreign/unknown CC (+45..., +14...) is left
# verbatim and 404s (the safety fallback) rather than being silently rewritten
# to a wrong number.
# repl_exp uses \1..\2 backreferences from match_exp capture groups.
sqlite3 "${KAMAILIO_DB}" <<'SQL'
BEGIN;
DELETE FROM dialplan WHERE dpid = 4;

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 1, 1, '^\+20(1[5-9][0-9]{9})$',   0, '^\+20(1[5-9][0-9]{9})$',     '\1', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 2, 1, '^\+20([5-9][0-9]{9})$',    0, '^\+20([5-9][0-9]{9})$',      '1\1', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 3, 1, '^\+?(1[5-9][0-9]{9})$',    0, '^\+?(1[5-9][0-9]{9})$',      '\1', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 4, 1, '^0(1[5-9][0-9]{9})$',      0, '^0(1[5-9][0-9]{9})$',        '\1', '', 0);

INSERT INTO dialplan (dpid, pr, match_op, match_exp, match_flags, subst_exp, repl_exp, attrs, match_len)
VALUES (4, 5, 1, '^00(20)?(1[5-9][0-9]{9})$',0, '^00(20)?(1[5-9][0-9]{9})$',  '\2', '', 0);
COMMIT;
SQL

echo "[+] Seeded dpid=4 dialplan rules into ${KAMAILIO_DB}:"
sqlite3 -header -column "${KAMAILIO_DB}" \
  "SELECT pr, match_exp AS 'match', match_op AS 'op', repl_exp AS 'repl' FROM dialplan WHERE dpid=4 ORDER BY pr;"
echo "[+] Done. ${KAMAILIO_DB} has $(sqlite3 "${KAMAILIO_DB}" "SELECT COUNT(*) FROM dialplan WHERE dpid=4;") dpid=4 rule(s)."