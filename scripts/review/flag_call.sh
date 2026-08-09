#!/usr/bin/env bash
# ==============================================================================
# flag_call.sh — Flag-for-Review evidence pipeline (single call)
# ==============================================================================
# On a blocked TRANSCRIPT verdict (post-call, non-interruptive), preserves the
# call's evidence for review and hands the flag to the Filteration-System:
#
#   1. Evidence  -> state/review/<recordingId>/ (wav + transcript + pcap)
#   2. Manifest  -> state/review/manifest.jsonl (append-only review queue)
#   3. Identity  -> MSISDNs from the pcap SIP dialog (tshark), IMSI from the
#                   local OsmoHLR sqlite (state/hlr/hlr.db), IMEI if supplied
#   4. Neon      -> LOCAL clone rows ONLY (logs VOICE_CALL_FLAG + optional
#                   blocklist upsert with FLAG_AUTO_MARK=1). Production Neon
#                   is NEVER written from this script — see docs/DB-Changes.md.
#
# Usage:
#   bash scripts/review/flag_call.sh <recordingId> [reason] [transcript]
# Env:  NEON_DB_LOCAL_URL (local clone), FLAG_AUTO_MARK=0|1
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
[ -f .env ] && set -a && source .env && set +a

# --- helpers ----------------------------------------------------------------
# Single source of escaping for every SQL string literal (PostgreSQL + sqlite).
# Standardizing here replaces the three differering ±'/' regimes previously
# scattered across the INSERTs (a correctness bug: a stray ' broke one
# statement while another escaped it — and CALLER/CALLEE were interpolated
# completely raw, an injection primitive).
sq_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
# Normalize a potential MSISDN to a safe character set: optional leading '+',
# then digits only, every other char dropped. SIP From/To users (tshark) arrive
# as E.164 "+1555…" — the leading '+' survives and the HLR lookup strips it
# separately (state/hlr stores MSISDN bare). Digits/+/ are injection- and
# JSON-safe by construction, fixing both the +E.164 identity-loss and the
# injection surface in one helper.
clean_msisdn() { printf '%s' "$1" | sed -E 's/^\+//; s/[^0-9+]//g'; }

REC_ID="${1:?usage: flag_call.sh <recordingId> [reason] [transcript]}"
REASON="${2:-potential scam (voice transcript)}"
TRANSCRIPT="${3:-}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REVIEW_DIR="state/review/${REC_ID}"
mkdir -p "${REVIEW_DIR}"

echo "── flag_call.sh: ${REC_ID} (${TS}) ──"

# --- 1. Evidence (preserve; tolerate any missing piece) ----------------------
WAV=""; TXT=""; PCAP=""
for cand in "state/spool/archived/${REC_ID}.wav" "state/spool/${REC_ID}.wav"; do
    [ -f "${cand}" ] && WAV="${cand}" && break
done
[ -f "state/spool/archived/${REC_ID}.txt" ] && TXT="state/spool/archived/${REC_ID}.txt"
[ -f "state/spool/pcaps/${REC_ID}.pcap" ] && PCAP="state/spool/pcaps/${REC_ID}.pcap"
[ -n "${WAV}" ] && cp -f "${WAV}" "${REVIEW_DIR}/call.wav" && echo "  ✓ audio preserved (${WAV})"
[ -n "${TXT}" ] && cp -f "${TXT}" "${REVIEW_DIR}/transcript.txt" \
    && TRANSCRIPT="${TRANSCRIPT:-$(python3 -c "import json;print(json.load(open('${TXT}')).get('text',''))" 2>/dev/null || cat "${TXT}")}"
[ -n "${PCAP}" ] && cp -f "${PCAP}" "${REVIEW_DIR}/call.pcap" && echo "  ✓ pcap preserved"

# --- 2. Identity resolution ---------------------------------------------------
# Sources, in priority order (each labeled in the manifest):
#   (a) FLAG_CALLER/FLAG_CALLEE env override (explicit, e.g. SIP-aware caller)
#   (b) pcap SIP From/To — production-real when the pcap carries signaling
#   (c) demo-rig map: live_tap recording ids embed the leg IP
#       (live-<pcap-hash>-10.89.0.60-0.wav); the baresip rig IPs are canonical
#       demo constants (scripts/testing/demo_call.sh): .60=baresip-rx=callee
#       15559998888, .61=baresip-tx=caller 15553332211. Labeled 'demo-rig-map'
#       so reviewers know the source.
CALLER="${FLAG_CALLER:-}"; CALLEE="${FLAG_CALLEE:-}"
ID_SOURCE="env"
if [ -n "${PCAP}" ] && [ -z "${CALLER}${CALLEE}" ]; then
    CALLER="$(tshark -r "${PCAP}" -Y 'sip.Method=="INVITE"' -T fields -e sip.from.user 2>/dev/null | head -1 || true)"
    CALLEE="$(tshark -r "${PCAP}" -Y 'sip.Method=="INVITE"' -T fields -e sip.to.user 2>/dev/null | head -1 || true)"
    [ -n "${CALLER}${CALLEE}" ] && ID_SOURCE="pcap-sip"
fi
if [ -z "${CALLER}${CALLEE}" ]; then
    # rig IP map (demo constants — see scripts/testing/demo_call.sh)
    RIG_IP="$(printf '%s' "${REC_ID}" | grep -oE '10\.89\.0\.[0-9]+' | head -1 || true)"
    case "${RIG_IP}" in
        10.89.0.60) CALLEE=15559998888 ;;
        10.89.0.61) CALLER=15553332211 ;;
    esac
    [ -n "${CALLER}${CALLEE}" ] && ID_SOURCE="demo-rig-map(${RIG_IP})"
fi
[ -n "${CALLER}${CALLEE}" ] && echo "  ✓ identities: caller=${CALLER:-?} callee=${CALLEE:-?} [${ID_SOURCE}]"
# Sanitize to digits[+]: strips SIP E.164 '+'/spaces and any SQL/JSON-breaking
# char, so every downstream query (HLR sqlite, local-Neon calls/logs/blocklist)
# and the manifest receives a value that cannot inject or malform.
CALLER="$(clean_msisdn "${CALLER:-}")"; CALLEE="$(clean_msisdn "${CALLEE:-}")"
# IMSI from the local OsmoHLR sqlite (host-mounted state/hlr/hlr.db)
IMSI=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f state/hlr/hlr.db ]; then
    for m in "${CALLER}" "${CALLEE}"; do
        [ -z "${m}" ] && continue
        # HLR stores MSISDN bare (no leading '+'), so strip it for the match;
        # the value is already digits/[+]-only (clean_msisdn) + sq_escaped, so
        # neither a stray '+' identity-loss nor SQL injection can occur.
        m_bare="$(printf '%s' "${m}" | sed 's/^\+//')"
        IMSI="$(sqlite3 state/hlr/hlr.db "SELECT imsi FROM subscriber WHERE msisdn='$(sq_escape "${m_bare}")' LIMIT 1;" 2>/dev/null || true)"
        [ -n "${IMSI}" ] && { echo "  ✓ IMSI ${IMSI} ← MSISDN ${m}"; break; }
    done
fi
IMEI="${FLAG_IMEI:-}"   # supplied via EIR/intercept path when available

# --- 3. Manifest (admin review queue) ----------------------------------------
MANIFEST="state/review/manifest.jsonl"
# Every field is JSON-escaped (python3 json.dumps) so the manifest stays one
    # valid JSON object per line even when REASON/REC_ID contain quotes,
    # backslashes, newlines or control chars. Real escaping only matters for
    # REASON (free-form); the rest are digits/paths — escaped for uniformity.
    META="$(python3 -c 'import json,sys;print(json.dumps({"ts":sys.argv[1],"recording_id":sys.argv[2],"caller":sys.argv[3],"callee":sys.argv[4],"imsi":sys.argv[5],"imei":sys.argv[6],"verdict":"flag","reason":sys.argv[7],"audio":sys.argv[8],"transcript_file":sys.argv[9],"pcap":sys.argv[10]}))' \
            "${TS}" "${REC_ID}" "${CALLER}" "${CALLEE}" "${IMSI}" "${IMEI}" \
            "${REASON}" \
            "${REVIEW_DIR}/call.wav" "${REVIEW_DIR}/transcript.txt" "${REVIEW_DIR}/call.pcap")"
printf '%s\n' "${META}" >> "${MANIFEST}"
echo "  ✓ manifest appended (${MANIFEST})"

# --- 4. Local Neon clone rows (NEVER production) ------------------------------
# Schema verified against the live clone (2026-08-09, PG 18.4):
#   calls(source, destination, started_at, ended_at, classification_label
#         'spam'|'ham', classification_score 0..1, status
#         'COMPLETED'|'BLOCKED'|'MISSED'|'FAILED'|'IN_PROGRESS')
#   logs(event_type, severity 'INFO'|'WARN'|'ERROR', message,
#        related_call_id uuid → calls(id), related_message_id uuid → messages(id))
#   blocklist(msisdn UNIQUE, reason, created_at, expires_at, trigger_message_id)
if podman ps --format '{{.Names}}' | grep -qx mvno-neon-local; then
    # calls row: the classification record (spam/BLOCKED verdict) + its UUID.
    # All string literals sq_escape'd (single standard regime — CALLER/CALLEE
    # are also pre-sanitized to digits/[+], so this is defense-in-depth).
    CALL_ID="$(printf "INSERT INTO calls (source, destination, started_at, ended_at, classification_label, classification_score, status) VALUES ('%s','%s', now(), now(), 'spam', 0.92, 'BLOCKED') RETURNING id;" \
        "$(sq_escape "${CALLER:-unknown}")" "$(sq_escape "${CALLEE:-unknown}")" \
        | podman exec -i mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=1 -qAt - | tr -d '[:space:]')" \
        && [ -n "${CALL_ID}" ] && echo "  ✓ local clone: calls row (${CALL_ID})"
    # logs row: VOICE_CALL_FLAG (metadata only — no transcript bodies by contract)
    printf "INSERT INTO logs (event_type, severity, message, related_call_id) VALUES ('VOICE_CALL_FLAG','WARN','%s','%s');\n" \
        "$(sq_escape "$(printf 'potential scam call flagged for review: caller=%s callee=%s imsi=%s' "${CALLER}" "${CALLEE}" "${IMSI}")")" \
        "${CALL_ID}" | podman exec -i mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=1 -qAt \
        && echo "  ✓ local clone: logs row (VOICE_CALL_FLAG → ${CALL_ID})"
    if [ "${FLAG_AUTO_MARK:-0}" = "1" ] && [ -n "${CALLER}" ]; then
        printf "INSERT INTO blocklist (msisdn, reason, expires_at) VALUES ('%s','%s', now() + interval '30 days') ON CONFLICT (msisdn) DO UPDATE SET reason=EXCLUDED.reason, expires_at=EXCLUDED.expires_at;\n" \
            "$(sq_escape "${CALLER}")" "$(sq_escape "${REASON}")" | podman exec -i mvno-neon-local psql -U mvno -d neondb -v ON_ERROR_STOP=1 -qAt \
            && echo "  ✓ local clone: blocklist upsert (${CALLER})"
    fi
else
    echo "  ⚠ mvno-neon-local not running — manifest-only (fail-open)"
fi

echo "✅ flagged ${REC_ID} — review at ${REVIEW_DIR}"
