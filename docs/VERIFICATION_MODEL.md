# MVNO Verification Model — Single Source of Truth

This document is the **authoritative contract** for every validator in the
repo: what each one asserts, how many cells/items it reports, which evidence
file it writes, and how the layers relate. If a doc, script, or demo quotes an
assertion count that disagrees with this table, **this table wins** — fix the
other reference.

Last updated: 2026-08-08 (post runbook-fragmentation restructure).

---

## 1. The layers at a glance

| Layer | Entry point | Runs | Role | Needs mic/TTY? | Exit-only? |
|---|---|---|---|---|---|
| **Presentation** | `docs/LIVE_DEMO.md` | human, pastes blocks | the 10-section narrated demo (S1–S10) | yes (S4/S5) | no |
| **Deterministic oracle** | `make gate` → `scripts/testing/gate.sh` | script | repeatable, exit-code-only certification | **no** | **yes** |
| **Live showcase** | `scripts/testing/live_demo.sh` | script | the labelled 13-item interactive demo on top of the gate | yes | no (narrated) |
| **SMS matrix** | `scripts/testing/sms_matrix.sh` | script | exit-only multi-cell 2G↔5G SMS interworking + AI-block | no | **yes** |
| **5G preflight** | `scripts/testing/preflight_5g.sh` | script (called by gate + live_demo) | 5G SA user-plane probe (ue-1 attach, GTP-U DL, NRF) | no | yes |
| **Helpers** | `make test-*`, `vty.sh`, `send_*.sh`, `intercept_live.sh` | manual/debug | developer utilities | n/a | n/a |

**Naming rule** (this is why the old names were misleading): the word
"runbook" is **not** used for these scripts anymore — it is reserved for
operational deployment docs (`docs/deployment_guide.md`). The three validator
scripts are named for what they are:

- `gate.sh` — the aggregator/oracle.
- `live_demo.sh` — the **live** (interactive, mic/baresip) demo.
- `sms_matrix.sh` — the exit-only SMS **matrix** oracle.

---

## 2. Assertion counts (the contract)

| Validator | Reported count | What it means | Evidence file |
|---|---|---|---|
| `preflight_5g.sh` | 1 probe (multi-section) | 5G user plane UP: ue-1 `uesimtun0` IP readable, REGISTER 200 OK over the 5G path, GTP-U DL emitted (iptables OUTPUT 2152 delta), NRF 9/9 NFs | printed inline + gate log |
| `sms_matrix.sh` | **5 cells / 8 ok** | 2G→2G, 2G→5G, 5G→2G, 5G→5G, AI-block (each cell = 1+ ok asserts; total 8 ok) | `docs/evidence/e2e-run-<date>.log` |
| `live_demo.sh` | **13 items / 8 hard assertions** | the 13 numbered `[N/13]` items; some are narrated demos, 8 carry `pass()`/`fail()` hard asserts | `docs/evidence/demo-run-<date>.log` |
| `make gate` | 2 gates | gate 1 = preflight, gate 2 = sms_matrix → **exit 0 = everything deterministic green** | both logs above |

> **Historical drift fixed**: old docs quoted "8 cells", "13 items", "4-cell",
> "7 ok" interchangeably. The correct numbers are: **sms_matrix = 5 cells/8 ok**,
> **live_demo = 13 items**, **gate = 2 gates**. `ISSUES.md` entries quoting
> "7 ok" are historical run snapshots, not the current contract.

---

## 3. Call graph (who invokes whom)

```
make gate
  └─ gate.sh
       ├─ preflight_5g.sh          # gate 1/2 — 5G user plane
       └─ sms_matrix.sh            # gate 2/2 — SMS 5-cell matrix + AI-block

make graduation  (GRADUATION=1)
  └─ gate.sh                       # same, but caller-leg mic assert is mandatory

live_demo.sh
  ├─ demo_call.sh   (baresip rig: setup + dial)
  ├─ live_tap.sh    (pcap -> WAV extraction)
  ├─ preflight_5g.sh               # item 5b reuses the SAME shared probe (not a copy)
  ├─ sip_traffic_sim.py / send_smpp_sms.py / newest.sh / mic_probe.sh
  └─ (asserts overlap with gate is limited to the preflight; the 13 items are
      otherwise distinct live content — SMPP MO path, fail-open proofs, EIR,
      zero-balance 403, Grafana NOC)
```

**Dedup principle**: `live_demo.sh` does **not** re-assert the SMS matrix —
its SMS item (8/13) is a *different* path (user SMS → real SMPP MO → OsmoSMSC
GSM-7 → REST verdict). The only shared assertion is the 5G user-plane probe,
which both `gate.sh` and `live_demo.sh` delegate to the single
`preflight_5g.sh` (source of truth, never inlined twice).

---

## 4. Evidence hygiene

- Each exit-only runbook truncates its own day-file at start and stamps
  `RUN:<ts>`, so a green file = one clean pass and a red file = one honest
  failure (no curated mixing).
- `sms_matrix.sh` → `docs/evidence/e2e-run-<date>.log`
- `live_demo.sh` → `docs/evidence/demo-run-<date>.log`
- Re-entrancy locks are the UNIFIED registry in `scripts/lib/common.sh`
  (`MVNO_RUN_LOCKS` + `acquire_run_lock`) — gate, sms_matrix, live_demo, the
  cockpit and the proof harnesses all use the same helper, and the watchdog's
  `run_in_flight` guard consults the same registry + tmux session + pgrep set.
  A new orchestrator registers once in common.sh and is automatically guarded
  everywhere (no per-script lock lists to keep in sync).
- Historical evidence files are append-only snapshots — never edit old runs to
  match today's names.

---

## 5. How to change an assertion (keep the contract honest)

1. Edit the script, then **update this table** (count + meaning) in the same
   commit — no script change ships without its contract line.
2. If the count changes, grep the repo for the old number in docs and update
   (`git grep -n "8 ok"`, `git grep -n "13 items"` …).
3. Re-run the affected validator and commit its fresh evidence log.

---

## 6. Single source of truth (subscribers + run-guard)

- The MVNO test-subscriber topology lives in **`scripts/lib/common.sh`**
  (`MVNO_MSISDN_*`, `MVNO_UAS_AOR`, `MVNO_MSISDN_2G`, `MVNO_BARESIP_AORS`,
  `MVNO_THROWAWAY`). Scripts reference the constants instead of hardcoding
  MSISDNs — the shared UAS AoR (preflight probe, live_demo UAS blocks,
  baresip-rx) and the bridge-owned 2G AoRs (which must NEVER be deregistered)
  are the two historical collision points this settles.
- **`make check-subs`** (`scripts/check-subscribers.sh`) enforces the set
  against every script + the Makefile seeds (incl. the zero-balance 403 and
  funded-100 contracts) and runs inside the gate as **gate 0/3** — a drifted
  constant fails the gate before any live assertion can mislead.
- The watchdog's `run_in_flight` guard, the cockpit/live_demo collision check
  (both hold the UAS AoR), and the proof harness locks all share the same
  registry — orchestrators are settled by construction, not by convention.

---

## 7. Issue documentation workflow (Status discipline)

Every new entry in **docs/ISSUES.md** must pass the mechanical gate
(`make check-issues`, also wired into the pre-push hook) — a plan or intent
alone cannot guarantee non-redundancy or verified genuineness:

1. **Report** — log the raw symptom with `* Status: AO` (audited-only). An
   observation is never a confirmed issue on its own; a tool mishap or a probe
   artifact is a `C` (closed non-fault) under **§11 Not-Issues**, not an issue.
2. **Verify** — capture real evidence (a live log line, a cold-start
   reproduction, or a probe). Promote to `LL` (live-log verified) or `RC`
   (reproduced on cold-start); if the symptom evaporates, reclassify as `C`.
3. **Dedup** — grep the header **Keyword Index (SSOT)**; if the symptom
   matches an anchor, EXTEND that issue (bump Status, add the new data point)
   instead of filing a new number. `check-issues.sh` hard-fails on a candidate
   duplicate (≥2 shared title tokens above the frontier, or a keyword mapping
   to two anchors) — a planted re-file is the regression test for this.
4. **Document** — add the block with `* Symptom / * Root Cause / * Fix /
   * Verification / * Status / * Verified-by`. New entries must use
   section-max+1 (frontier is `<!-- check-issues frontier: Issue 8.45 -->`;
   next free ID is 8.46) and a valid Status enum (`LL`/`RC`/`AO`/`X`/`C`).
5. **Close** — when fixed, flip `* Status: X (resolved by <commit>)` — never
   delete an entry (ISSUES.md is the authoritative doc). Legacy entries still
   missing Status surface as the check-issues WARN backfill queue.
