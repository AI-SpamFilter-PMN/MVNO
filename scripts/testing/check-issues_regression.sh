#!/usr/bin/env bash
# Planted-duplicate regression tests for scripts/check-issues.sh — run after
# editing the gate or ISSUES.md structure. All four planted fixtures must FAIL
# (rc=1) and the negative control (real file) must stay green (rc=0). T1/T3
# cover the two audited failure modes (re-filing a baresip/glibc issue;
# keyword-index collision).
cd /home/zkhattab/AI-SpamFilter-PMN/MVNO
SRC=docs/ISSUES.md

echo '=== T1: planted re-file "baresip glibc" as Issue 8.46 (full fields) — expect FAIL on token dup ==='
cp "$SRC" /tmp/fx1.md
printf '\n### Issue 8.46: baresip glibc regression after cold start\n\n* **Symptom**: x\n* **Root Cause**: x\n* **Fix**: x\n* **Verification**: x\n* **Status**: AO\n' >> /tmp/fx1.md
CHECK_ISSUES_FILE=/tmp/fx1.md bash scripts/check-issues.sh > /tmp/t1.out 2>&1
echo "T1 rc=$? (expect 1)"
grep -E 'candidate duplicate|invalid Status|missing required' /tmp/t1.out | head -2

echo
echo '=== T2: new entry missing Status — expect FAIL on missing required Status ==='
cp "$SRC" /tmp/fx2.md
printf '\n### Issue 8.46: nrf heartbeat flap\n\n* **Symptom**: x\n* **Root Cause**: x\n* **Fix**: x\n* **Verification**: x\n' >> /tmp/fx2.md
CHECK_ISSUES_FILE=/tmp/fx2.md bash scripts/check-issues.sh > /tmp/t2.out 2>&1
echo "T2 rc=$? (expect 1)"
grep -E 'missing required|missing required field' /tmp/t2.out | head -2

echo
echo '=== T3: keyword-index collision (glibc -> 8.30 AND -> 8.39) — expect FAIL ==='
cp "$SRC" /tmp/fx3.md
sed -i '/^> \* `glibc` → Issue 8.30$/a > * `glibc` → Issue 8.39' /tmp/fx3.md
CHECK_ISSUES_FILE=/tmp/fx3.md bash scripts/check-issues.sh > /tmp/t3.out 2>&1
echo "T3 rc=$? (expect 1)"
grep -E 'keyword index' /tmp/t3.out | head -2

echo
echo '=== T4: duplicate Issue ID (second 8.45) — expect FAIL on dup ID ==='
cp "$SRC" /tmp/fx4.md
printf '\n### Issue 8.45: fake duplicate of the cold-start issue\n\n* **Symptom**: x\n* **Root Cause**: x\n* **Fix**: x\n* **Verification**: x\n* **Status**: AO\n' >> /tmp/fx4.md
CHECK_ISSUES_FILE=/tmp/fx4.md bash scripts/check-issues.sh > /tmp/t4.out 2>&1
echo "T4 rc=$? (expect 1)"
grep -E 'duplicate Issue ID' /tmp/t4.out | head -2

echo
echo '=== T5 (negative control): real file must stay green ==='
bash scripts/check-issues.sh > /tmp/t5.out 2>&1
echo "T5 rc=$? (expect 0)"
tail -1 /tmp/t5.out

echo
echo '=== T6: same-domain issue WITH audited * Distinct-from: anchor — expect PASS ==='
cp "$SRC" /tmp/fx6.md
# Insert a FRESH ID (8.51) BEFORE the '## 11. Not-Issues' section so its
# Status: AO line is not read as a Not-Issues entry (which requires C).
awk '/^## 11\./{print "### Issue 8.51: baresip glibc regression after cold start"; print ""; print "* **Symptom**: x"; print "* **Root Cause**: x"; print "* **Fix**: x"; print "* **Verification**: x"; print "* **Status**: AO"; print "* Distinct-from: Issue 8.30 — different RCA (glibc ABI vs cold-start ordering)"; print "* Distinct-from: Issue 8.36 — different RCA (glibc ABI vs cold-start ordering)"; print "* Distinct-from: Issue 8.45 — different RCA (cold-start ordering vs glibc ABI)"; print ""; print ""} {print}' "$SRC" > /tmp/fx6.md
CHECK_ISSUES_FILE=/tmp/fx6.md bash scripts/check-issues.sh > /tmp/t6.out 2>&1
echo "T6 rc=$? (expect 0)"
grep -E 'candidate duplicate|distinct-from|missing required' /tmp/t6.out | head -2

echo
echo '=== T7: same-domain issue WITHOUT Distinct-from — expect FAIL (re-file blocked) ==='
cp "$SRC" /tmp/fx7.md
awk '/^## 11\./{print "### Issue 8.51: baresip glibc regression after cold start"; print ""; print "* **Symptom**: x"; print "* **Root Cause**: x"; print "* **Fix**: x"; print "* **Verification**: x"; print "* **Status**: AO"; print ""; print ""} {print}' "$SRC" > /tmp/fx7.md
CHECK_ISSUES_FILE=/tmp/fx7.md bash scripts/check-issues.sh > /tmp/t7.out 2>&1
echo "T7 rc=$? (expect 1)"
grep -E 'candidate duplicate' /tmp/t7.out | head -2
rm -f /tmp/fx*.md /tmp/t*.out
