#!/usr/bin/env bash
# =============================================================================
# check-issues.sh — read-only ISSUES.md hygiene gate (dedup / structure / status)
#
#   bash scripts/check-issues.sh          # exit 0 = clean, exit 1 = violation
#   bash scripts/check-issues.sh -v       # verbose: per-issue field report
#
# Enforces the issue-documentation mechanism (2026-08-08 audit plan):
#   1. Issue-ID uniqueness + monotonic numbering. Gaps / out-of-order are a
#      WARN (history cannot be renumbered without churn); a duplicate ID is a
#      HARD FAIL, and a NEW entry (above the frontier marker) must be
#      section-max+1.
#   2. Required fields per issue block: * Symptom, * Root Cause, * Fix,
#      * Verification — and, for issues ABOVE the frontier marker, a
#      * Status line with a valid enum (LL/RC/AO/X/C). Legacy entries are
#      grandfathered and surfaced as a WARN backfill queue.
#   3. Title-token dedup: two issues sharing >=2 significant title tokens is a
#      candidate duplicate — a HARD FAIL if either side is above the frontier
#      (a planted "baresip glibc" re-file must fail), else a WARN cluster
#      (extend the anchor instead of re-filing).
#   4. The header Keyword Index (SSOT): every `keyword → Issue X.Y` must map
#      to an existing issue, a keyword must map to exactly ONE issue
#      (duplicate keyword = FAIL), and the keyword must actually appear in the
#      anchor issue's block.
#   5. The Status legend must exist in the header (new entries require Status,
#      so the enum contract must be discoverable).
#
# NOTE: backticks are literal in grep ERE — do NOT escape them (\` does not
# match in GNU grep).
#
# Static + no stack required; wired into `make check-issues` and the pre-push
# hook alongside check-glossary.sh. CHECK_ISSUES_FILE overrides the target for
# tests (e.g. planted-duplicate fixtures).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ISSUES="${CHECK_ISSUES_FILE:-docs/ISSUES.md}"
[ -f "$ISSUES" ] || { echo "✗ ERROR: $ISSUES missing"; exit 1; }

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

OK=0; WARN=0; FAIL=0
ok()   { OK=$((OK+1)); }
warn() { WARN=$((WARN+1)); printf '  ⚠ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Frontier: issues ABOVE this are subject to the strict new-entry contract.
# ---------------------------------------------------------------------------
FRONTIER="$(sed -nE 's/.*check-issues frontier: Issue ([0-9]+\.[0-9]+).*/\1/p' "$ISSUES" | head -1)"
F_MAJ="${FRONTIER%%.*}"; F_MIN="${FRONTIER##*.}"
case "$F_MAJ" in ''|*[!0-9]*) F_MAJ=0; F_MIN=0;; esac

gt_frontier() { # $1=MAJ $2=MIN → true if MAJ.MIN > F_MAJ.F_MIN
  if   [ "$1" -gt "$F_MAJ" ]; then return 0
  elif [ "$1" -eq "$F_MAJ" ] && [ "$2" -gt "$F_MIN" ]; then return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 5. Status legend must exist in the header region.
# ---------------------------------------------------------------------------
HDR_REGION="$(sed -n '1,/^## /p' "$ISSUES")"
if ! printf '%s' "$HDR_REGION" | grep -qE '`(LL|RC|AO|X|C)`'; then
  fail "Status legend missing from header (enum \`LL\`/\`RC\`/\`AO\`/\`X\`/\`C\` not documented)"
else
  ok
fi

# ---------------------------------------------------------------------------
# 1. Gather issue headers: line, ID (MAJ.MIN), title.
# ---------------------------------------------------------------------------
# Section headers (## N. …) are block boundaries too — an issue block must
# NEVER span a section header, otherwise the last issue would swallow the §11
# Not-Issues Status lines and a genuinely missing * Status: could false-PASS.
# Field delimiter is \x1f (unit separator) — titles may contain '|' but not \x1f.
ISEP=$'\x1f'
declare -a LINES IDS MAJORS MINS TITLES SECLINES
mapfile -t HDR_LINES < <(grep -nE '^### Issue [0-9]+\.[0-9]+' "$ISSUES" | sed -E "s/^([0-9]+):### Issue ([0-9]+)\\.([0-9]+): (.*)$/\1${ISEP}\2${ISEP}\3${ISEP}\4/")
mapfile -t SECLINES < <(grep -nE '^## ' "$ISSUES" | cut -d: -f1)
N="${#HDR_LINES[@]}"
[ "$N" -eq 0 ] && { fail "no '### Issue X.Y' headers found in $ISSUES"; echo; echo "check-issues: $OK ok, $WARN warn, $FAIL fail"; exit 1; }

idx=0
for h in "${HDR_LINES[@]}"; do
  IFS="$ISEP" read -r ln maj min title <<<"$h"
  LINES[$idx]="$ln"; MAJORS[$idx]="$maj"; MINS[$idx]="$min"; TITLES[$idx]="$title"
  IDS[$idx]="$maj.$min"
  idx=$((idx+1))
done

# --- duplicate ID check ---
for ((i=0; i<N; i++)); do
  for ((j=i+1; j<N; j++)); do
    if [ "${IDS[$i]}" = "${IDS[$j]}" ]; then
      fail "duplicate Issue ID ${IDS[$i]} at lines ${LINES[$i]} and ${LINES[$j]}"
    fi
  done
done
[ "$FAIL" -eq 0 ] && ok

# --- numbering: out-of-order and gaps are WARN (history); new = max+1 ---
PREV_KEY="000.000"
OOO_NOTE=""
for ((i=0; i<N; i++)); do
  key=$(printf '%03d.%03d' "${MAJORS[$i]}" "${MINS[$i]}")
  if [[ "$PREV_KEY" != "000.000" && "$key" < "$PREV_KEY" ]]; then
    OOO_NOTE+=" ${IDS[$i]}"
  fi
  PREV_KEY="$key"
done

# gap detection: for dense series (>=6 issues in one major), list missing minors
declare -A SERIES
for ((i=0; i<N; i++)); do SERIES["${MAJORS[$i]}"]+="${MINS[$i]} "; done
GAP_NOTE=""
for major in "${!SERIES[@]}"; do
  read -r -a mins <<<"${SERIES[$major]}"
  [ "${#mins[@]}" -lt 6 ] && continue
  minv=$(printf '%s\n' "${mins[@]}" | sort -n | head -1)
  maxv=$(printf '%s\n' "${mins[@]}" | sort -n | tail -1)
  missing=""
  for ((m=minv; m<=maxv; m++)); do
    case " ${mins[*]} " in *" $m "*) ;; *) missing+=" $m";; esac
  done
  [ -n "$missing" ] && GAP_NOTE+=" $major.x missing:$missing"
done

if [ -n "$OOO_NOTE" ] || [ -n "$GAP_NOTE" ]; then
  warn "numbering not strictly monotonic (pre-existing history): out-of-order:$OOO_NOTE gaps:$GAP_NOTE — NEW entries must use max+1"
else
  ok
fi

# ---------------------------------------------------------------------------
# 2. Per-issue field checks (block = up to the next '### ' header).
# ---------------------------------------------------------------------------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

declare -a BLOCKFILES
for ((i=0; i<N; i++)); do
  start="${LINES[$i]}"
  endline=""   # empty = end of file
  if [ $((i+1)) -lt "$N" ]; then endline=$(( LINES[$((i+1))] - 1 )); fi
  # stop at the first section header after this issue (never span '## ' sections)
  for sl in "${SECLINES[@]}"; do
    [ "$sl" -le "$start" ] && continue
    if [ -z "$endline" ] || [ "$sl" -lt "$endline" ]; then endline=$(( sl - 1 )); fi
    break
  done
  bf="$TMPD/b$i"
  if [ -n "$endline" ]; then sed -n "${start},${endline}p" "$ISSUES" > "$bf"; else sed -n "${start},\$p" "$ISSUES" > "$bf"; fi
  BLOCKFILES[$i]="$bf"
done

declare -a LEGACY_NO_STATUS LEGACY_MISSING_BLOCKS
for ((i=0; i<N; i++)); do
  bf="${BLOCKFILES[$i]}"
  maj="${MAJORS[$i]}"; min="${MINS[$i]}"
  if gt_frontier "$maj" "$min"; then is_new=1; else is_new=0; fi

  missing=()
  for f in "Symptom" "Root Cause" "Fix" "Verification"; do
    if ! grep -qE "^\* (\*\*)?${f}(\*\*)?( \([^)]*\))?:" "$bf"; then
      missing+=("$f")
    fi
  done

  has_status=0
  if grep -qE "^\* (\*\*)?Status(\*\*)?:" "$bf"; then
    has_status=1
    status_val="$(sed -nE "s/^\* (\*\*)?Status(\*\*)?: *([A-Za-z]+).*/\3/p" "$bf" | head -1)"
    if ! printf '%s' "$status_val" | grep -qE '^(LL|RC|AO|X|C)$'; then
      fail "Issue ${IDS[$i]}: invalid Status value '${status_val:-<empty>}' (must be LL/RC/AO/X/C)"
    fi
  fi

  if [ "$is_new" -eq 1 ]; then
    # New entry: all four blocks + Status are mandatory.
    for f in "${missing[@]}"; do
      fail "Issue ${IDS[$i]}: missing required field * ${f}: (above frontier ${FRONTIER:-0.0})"
    done
    if [ "$has_status" -eq 0 ]; then
      fail "Issue ${IDS[$i]}: missing required * Status: line (above frontier ${FRONTIER:-0.0})"
    fi
    [ "$has_status" -eq 1 ] && [ "${#missing[@]}" -eq 0 ] && ok
  else
    # Legacy: backfill queue (WARN); a present-but-malformed Status is FAIL above.
    if [ "$has_status" -eq 0 ]; then
      LEGACY_NO_STATUS+=("${IDS[$i]}")
    fi
    for f in "${missing[@]}"; do
      LEGACY_MISSING_BLOCKS+=("${IDS[$i]}:$f")
    done
  fi
  [ "$VERBOSE" -eq 1 ] && [ "$is_new" -eq 1 ] && printf '  · %s (%s): fields %s status=%s\n' "${IDS[$i]}" "${TITLES[$i]}" "$([ ${#missing[@]} -eq 0 ] && echo full || echo "missing:${missing[*]}")" "${status_val:--}"
done

if [ "${#LEGACY_NO_STATUS[@]}" -gt 0 ]; then
  list="$(printf '%s ' "${LEGACY_NO_STATUS[@]:0:8}")"
  warn "legacy backfill queue: ${#LEGACY_NO_STATUS[@]} issue(s) lack * Status: — e.g. ${list}… (backfill LL/RC/AO/X/C, then it disappears)"
fi
if [ "${#LEGACY_MISSING_BLOCKS[@]}" -gt 0 ]; then
  list="$(printf '%s ' "${LEGACY_MISSING_BLOCKS[@]:0:8}")"
  warn "legacy backfill queue: ${#LEGACY_MISSING_BLOCKS[@]} missing field(s) — e.g. ${list}… (add the block or mark Status: C)"
fi

# ---------------------------------------------------------------------------
# 3. Title-token dedup (>=2 shared significant tokens = candidate duplicate).
# ---------------------------------------------------------------------------
# A NEW issue that shares >=2 tokens with any anchor is a candidate re-file and
# FAILs — UNLESS the new block carries an explicit, auditable
#   * Distinct-from: Issue X.Y — <one-line RCA difference>
# line naming that anchor. The annotation is a conscious disambiguation (a
# planted re-file would have to falsely claim distinctness in review), so
# same-domain-but-different-RCA issues can pass while silent re-files cannot.
STOPWORDS="the a an of in on for to with vs after before during from into via over under and or not no up down out its it this that new fixed fix docs setup issue issues sh py md yaml port range"

sig_tokens() { # $1 = title string → significant lowercase tokens, one per line
  local s t
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ')"
  for t in $s; do
    case " $STOPWORDS " in *" $t "*) continue;; esac
    [ "${#t}" -lt 3 ] && continue
    printf '%s\n' "$t"
  done
}

for ((i=0; i<N; i++)); do
  sig_tokens "${TITLES[$i]}" | sort -u > "$TMPD/t$i"
done

disambiguated() { # $1=issue idx $2=anchor ID (MAJ.MIN) → 0 if * Distinct-from: names it
  local bf="${BLOCKFILES[$1]}"
  [ -f "$bf" ] || return 1
  grep -qE "^\* (\*\*)?Distinct-from(\*\*)?:.*${2//./\\.}" "$bf"
}

CLUSTER_NOTE=""
for ((i=0; i<N; i++)); do
  for ((j=i+1; j<N; j++)); do
    shared=$(comm -12 "$TMPD/t$i" "$TMPD/t$j" | wc -l)
    [ "$shared" -lt 2 ] && continue
    ia_new=0; ib_new=0
    gt_frontier "${MAJORS[$i]}" "${MINS[$i]}" && ia_new=1
    gt_frontier "${MAJORS[$j]}" "${MINS[$j]}" && ib_new=1
    if [ "$ia_new" -eq 1 ] || [ "$ib_new" -eq 1 ]; then
      # Audited escape: the NEW side must explicitly name the anchor it
      # overlaps with; otherwise it is a candidate re-file (FAIL).
      if [ "$ia_new" -eq 1 ] && disambiguated "$i" "${IDS[$j]}"; then
        CLUSTER_NOTE+=" ${IDS[$i]}↔${IDS[$j]}($shared,distinct-from)"
      elif [ "$ib_new" -eq 1 ] && disambiguated "$j" "${IDS[$i]}"; then
        CLUSTER_NOTE+=" ${IDS[$i]}↔${IDS[$j]}($shared,distinct-from)"
      else
        fail "candidate duplicate: Issue ${IDS[$i]} and ${IDS[$j]} share $shared significant title tokens — extend the existing issue instead of re-filing (or add an audited * Distinct-from: Issue ${IDS[$j]}/${IDS[$i]} line if the RCA is genuinely different)"
      fi
    else
      CLUSTER_NOTE+=" ${IDS[$i]}↔${IDS[$j]}($shared)"
    fi
  done
done
[ -z "$CLUSTER_NOTE" ] && ok || warn "title-token clusters among legacy issues:$CLUSTER_NOTE — extend anchors, do not re-file"

# ---------------------------------------------------------------------------
# 4. Keyword Index (SSOT) validation.
# ---------------------------------------------------------------------------
declare -a KW KW_TARGET
KW=(); KW_TARGET=()
KWN=0
while IFS='|' read -r kw tgt; do
  KW+=("$kw"); KW_TARGET+=("$tgt"); KWN=$((KWN+1))
done < <(printf '%s' "$HDR_REGION" | grep -oE '`[^`]+` → Issue [0-9]+\.[0-9]+' | sed -E 's/^`([^`]+)` → Issue ([0-9]+\.[0-9]+)$/\1|\2/')

if [ "$KWN" -eq 0 ]; then
  warn "header Keyword Index (SSOT) is empty or missing — add \`keyword → Issue X.Y\` lines"
else
  # duplicate keyword → FAIL (a keyword must map to exactly one anchor)
  for ((i=0; i<KWN; i++)); do
    for ((j=i+1; j<KWN; j++)); do
      if [ "${KW[$i]}" = "${KW[$j]}" ] && [ "${KW_TARGET[$i]}" != "${KW_TARGET[$j]}" ]; then
        fail "keyword index collision: \`${KW[$i]}\` maps to both Issue ${KW_TARGET[$i]} and ${KW_TARGET[$j]} — pick one anchor and extend it"
      fi
    done
  done
  for ((i=0; i<KWN; i++)); do
    tgt="${KW_TARGET[$i]}"; kw="${KW[$i]}"
    # target must exist
    found=0; anchor_idx=0
    for ((k=0; k<N; k++)); do
      if [ "${IDS[$k]}" = "$tgt" ]; then found=1; anchor_idx=$k; break; fi
    done
    if [ "$found" -eq 0 ]; then
      fail "keyword index: \`${kw}\` → Issue ${tgt} references a non-existent issue"
      continue
    fi
    # keyword must appear in the anchor's block
    if ! grep -qi "${kw}" "${BLOCKFILES[$anchor_idx]}"; then
      warn "keyword index: \`${kw}\` does not appear in Issue ${tgt}'s block — orphaned map entry"
    fi
  done
  [ "$FAIL" -eq 0 ] && ok
fi

# ---------------------------------------------------------------------------
# Not-Issues quarantine section should exist, and its entries must be C
# (closed non-fault) — anything else means it was filed as a real issue in
# the wrong place.
# ---------------------------------------------------------------------------
if grep -qE '^## 1[0-9]\. Not-Issues' "$ISSUES"; then
  ok
  NOTI_LINE="$(grep -nE '^## 1[0-9]\. Not-Issues' "$ISSUES" | head -1 | cut -d: -f1)"
  while read -r v; do
    [ "$v" = "C" ] || fail "Not-Issues entry has Status '$v' — must be C (closed non-fault)"
  done < <(sed -n "${NOTI_LINE},\$p" "$ISSUES" | sed -nE "s/^\* (\*\*)?Status(\*\*)?: *([A-Za-z]+).*/\3/p")
else
  warn "no Not-Issues quarantine section (## N. Not-Issues) — file audited-and-clear findings there as Status: C"
fi

# ---------------------------------------------------------------------------
echo
echo "check-issues: $OK ok, $WARN warn, $FAIL fail (frontier = Issue ${FRONTIER:-0.0})"
[ "$FAIL" -eq 0 ]
