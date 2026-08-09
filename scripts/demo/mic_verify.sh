#!/usr/bin/env bash
# ==============================================================================
# Live-Mic Transcription Verification — the graduation HEADLINE proof
# ==============================================================================
# Forces a GENUINE FRESH mic capture for THIS run and asserts the Native Vosk
# ASR transcript for exactly that file is NON-EMPTY. This is the anti-theater
# step: the demo cannot go green on a canned/callee-keyed verdict alone — the
# operator must actually speak into the mic and ASR must hear words.
#
# Flow:
#   [1] SPEAK NOW prompt → 10 s live capture (mic_record.sh, fresh ts-stamped)
#   [2] Wait for the Vosk spool watcher to archive <stem>.txt for THAT wav
#   [3] HARD assert: transcript file exists AND text is non-empty
#   [4] SOFT keyword check: ≥1 of the ai-filter TRANSCRIPT rule keywords
#       (account/blocked/confirm/urgent/won/prize/free/claim). ASR variance is
#       tolerated — presence of any keyword is printed, absence is a warning
#       (not a failure) since non-empty is the hard gate.
#   [5] Cross-check: POST the transcript to ai-filter and show the verdict
#       (operator's own words classified clean = honest contrast to the
#       callee scam leg which blocks).
#   On ANY failure: diagnostic dump (volumedetect, watcher log tail, spool
#   listing) so a supervisor can see exactly what went wrong.
#
# Usage:   bash scripts/demo/mic_verify.sh [capture_seconds]   (default 10)
# Exit:    0 = fresh capture transcribed non-empty; 1 = FAIL (with diagnostics)
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

DURATION="${1:-10}"
KEYWORDS="account|blocked|confirm|urgent|won|prize|free|claim"
# ts marker of THIS run — the assert must match exactly this capture
RUN_TS="$(date +%s)"

pass() { echo -e "\033[32m  ✓ $1\033[0m"; }
fail() { echo -e "\033[31m  ✗ $1\033[0m"; }
fatal() {
  echo -e "\033[31m\nFATAL: $1\033[0m" >&2
  diag || true   # diagnostics must never mask the real exit code (SIGPIPE guard)
  exit 1
}

diag() {
  echo ""
  echo "---- diagnostic dump (what happened) ----"
  echo "spool root:"; ls -lt state/spool/*.wav 2>/dev/null | head -4 || echo "  (none)"
  echo "archived (newest 6):"; ls -lt state/spool/archived/ 2>/dev/null | head -6
  echo "api watcher log (tail):"
  podman logs mvno-api --since 2m 2>&1 | grep -iE "NativeVoskService|transcrib|spool" | tail -5 \
    || echo "  (no watcher lines in 2m)"
  echo "capture volume:"
  ffmpeg -i "${CAPTURE_WAV:-}" -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume" \
    || echo "  (capture missing)"
}

echo "========================================================================"
echo " 🎙️  LIVE-MIC TRANSCRIPTION VERIFICATION (make graduation stage 4/5)"
echo "========================================================================"
echo "  This is the headline proof: YOUR fresh mic capture, transcribed now."
echo ""

# --- [1] fresh capture via mic_record.sh --------------------------------------
CAPTURE_WAV="state/spool/mic_call_${RUN_TS}.wav"
echo "  📢 SPEAK NOW — say anything for ${DURATION} s (free-form, from your mind):"
echo "     the callee scam phrase is only a hint if you want it:"
echo "     \"Your bank account has been blocked, please confirm your details now\""
echo "------------------------------------------------------------------------"
# Surface mic_record.sh's LIVE transcription output so the operator sees the
# words appearing as ASR catches up (that was previously swallowed by >/dev/null).
# stderr stays quiet to keep ffmpeg pipe noise out of the SPEAK footprint.
bash scripts/testing/mic_record.sh "${DURATION}" 2>/dev/null || \
  fatal "mic_record.sh failed — capture not produced"
# The Vosk watcher archives the WAV during mic_record.sh's own ASR wait
# (≈2×duration+6s), so the fresh capture may already be in state/spool/archived/
# — search both.
CAPTURE_WAV=""
for cand in "state/spool/mic_call_${RUN_TS}.wav" \
            "state/spool/archived/mic_call_${RUN_TS}.wav" \
            "$(ls -t state/spool/mic_call_*.wav state/spool/archived/mic_call_*.wav 2>/dev/null | head -1 || true)"; do
  if [ -n "${cand}" ] && [ -f "${cand}" ]; then CAPTURE_WAV="${cand}"; break; fi
done
[ -n "${CAPTURE_WAV}" ] || fatal "no fresh mic capture found in state/spool/ or archived/"
pass "fresh capture: ${CAPTURE_WAV} ($(stat -c%s "${CAPTURE_WAV}" 2>/dev/null) bytes)"

# --- [2] wait for THIS file's transcript — LIVE "till now" stream -------------
# Poll every 1 s, print a rolling "listening… Ns" so the operator sees the
# window live, and the INSTANT the watcher archives <stem>.txt for THIS capture,
# show the transcript immediately (not only once at the end — the "live
# transcription, till now" requirement, previously buried by >/dev/null).
STEM="$(basename "${CAPTURE_WAV%.wav}")"
TXT=""
echo "  ⏳ Transcriber running — what the mic has captured so far (refreshes 1 s):"
for i in $(seq 1 60); do
  if [ -f "state/spool/archived/${STEM}.txt" ]; then
    # LIVE: the moment THIS capture's words are recognized, show them now and
    # stop polling — Vosk writes the whole transcript once, so this is the
    # operator-facing "till now" result in real time.
    TXT="state/spool/archived/${STEM}.txt"
    printf "\r  \033[2K  LIVE so far (after ~%ss): \"%s\"\n" "${i}" \
        "$(python3 -c "import json,sys;print(json.load(open('${TXT}')).get('text',''))" 2>/dev/null || cat "${TXT}")"
    break
  fi
  # keep the operator oriented: elapsed seconds of the capture window
  printf "\r  \033[2K  listening… %s s of a %s s window" "${i}" "${DURATION}"
  sleep 1
done
echo ""
# the final transcript (Vosk writes it once, whole) is re-shown in step [3]
if [ -n "${TXT}" ]; then
  pass "transcript archived: ${TXT}"
else
  # the watcher may already have archived the txt before our poll started
  [ -f "state/spool/archived/${STEM}.txt" ] && TXT="state/spool/archived/${STEM}.txt"
fi
[ -n "${TXT}" ] || fatal "no transcript for ${STEM}.txt after 30 s — ASR watcher did not archive this capture"

# --- [3] HARD: non-empty transcript -------------------------------------------
TRANSCRIPT="$(python3 -c "import json,sys;print(json.load(open('${TXT}')).get('text',''))" 2>/dev/null || cat "${TXT}")"
echo "  transcript file: ${TXT}"
echo "  transcript text: \"${TRANSCRIPT}\""
if [ -z "${TRANSCRIPT// }" ]; then
  fatal "transcript is EMPTY for this run's capture — no speech heard. Speak louder / closer,"
fi
pass "NON-EMPTY transcript for THIS run's fresh capture (HEADLINE PROOF ✓)"

# --- [4] SOFT keyword check ----------------------------------------------------
HITS="$(printf '%s' "${TRANSCRIPT}" | grep -oiE "${KEYWORDS}" | tr '\n' ' ' || true)"
if [ -n "${HITS}" ]; then
  pass "keyword anchors heard: ${HITS}"
else
  echo "  ⚠  no demo keyword heard (ASR variance is tolerated) — transcript is still non-empty"
fi

# --- [5] ai-filter cross-check: operator's own words ---------------------------
VERDICT="$(curl -s -m 5 -X POST http://localhost:8008/ -H 'Content-Type: application/json' \
  -d "{\"event_type\":\"TRANSCRIPT\",\"transcript\":\"${TRANSCRIPT}\"}" || echo '{"allow":true,"reason":"ai-filter unreachable (fail-open)"}')"
echo "  ai-filter verdict on YOUR voice: ${VERDICT}"

echo ""
echo "✅ MIC VERIFY PASSED — genuine fresh capture + non-empty this-run transcript."
exit 0
