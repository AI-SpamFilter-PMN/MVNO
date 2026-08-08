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
- Re-entrancy locks (`/tmp/mvno-sms-matrix.lock`, `/tmp/mvno-live-demo.lock`)
  prevent two instances truncating the same evidence concurrently.
- Historical evidence files are append-only snapshots — never edit old runs to
  match today's names.

---

## 5. How to change an assertion (keep the contract honest)

1. Edit the script, then **update this table** (count + meaning) in the same
   commit — no script change ships without its contract line.
2. If the count changes, grep the repo for the old number in docs and update
   (`git grep -n "8 ok"`, `git grep -n "13 items"` …).
3. Re-run the affected validator and commit its fresh evidence log.
