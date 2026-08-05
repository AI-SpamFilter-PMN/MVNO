# Implementation Plan — Master Plan v7 (Goals 0–8; ALL DELIVERED ✅)

## Post-8 Addendum — One-Command Team Bring-Up (2026-08-03) ✅

**Deliverable**: `scripts/deploy.sh` — single entry point for a fresh teammate
machine: runtime+OS package install (apt/dnf/pacman), `modprobe sctp`, image
hydration via `pull-images.sh` (Docker Hub) or `load-offline.sh` (offline), `make init-db`,
`up.sh`, API health wait with bounded self-heal (`compose up` retry + restart of
exited containers). Verified green end-to-end (`RESULT: READY`, API `UP`, 31 services).

**Two pre-existing bugs found & fixed during verification** (exactly what a teammate
would have hit before this):
1. `up.sh` `CUSTOM_IMAGES` used bare names → `podman image exists` resolved `:latest`
   → false missing → forced `--build` (which failed on the missing prebuilt jar and a
   `state/grafana/csv` build-context stat error). Changed to the tagged pins matching
   `docker-compose.yml` and added the previously-skipped `mvno-2g-core` / `mvno-2g-ms`.
2. `make init-db` failed with `readonly database` after kamailio had run (container
   writes its WAL `-shm`/`-wal` as host-UID 101000); init-db now deletes the stale
   WAL artifacts before opening the DB.

**Companion**: the 8 custom `mvno-*` images are published public on Docker Hub
(`5attab007/mvno-*`) with per-repo descriptions; `pull-images.sh` + deployment-guide /
ONBOARDING one-liners point teammates there. README-level docs updated
(ONBOARDING §3/§4/§5, deployment_guide §Method B).

> **LIVE STATUS (final):** Goals 0–6 ✅, Goal 7 ✅, Goal 8 ✅ — all delivered & pushed to
> `origin/main`. `e2e_runbook.sh` exits 0 with **all 5 cells green** (4-cell SMS
> interworking matrix + AI-block), verified across two consecutive runs
> (2026-08-03 15:17 / 15:18 UTC, 7 ok each, EXIT=0).

## Goal 7 — e2e_runbook.sh ✅ COMPLETE

**Final result (two consecutive green runs, 15:17 / 15:18 UTC):**

| Cell | Assertion | Status | Implementation |
|------|-----------|--------|----------------|
| 1 | 2G→2G direct | ✅ PASS | `send_smpp_sms.py` → 2G SMSC; bridge counters verified unchanged |
| 2 | 2G→5G bridge | ✅ PASS | `inject_smsc_row.py` row → bridge poll → Kamailio relay → recv terminal (10.89.0.54) |
| 3 | 5G→2G bridge | ✅ PASS | dedicated sender (10.89.0.55) → bridge :5090 → SMPP → SMSC → MS1 sms.txt |
| 4 | 5G→5G Kamailio | ✅ PASS | sender (10.89.0.55) → twin relay → recv terminal (10.89.0.56); bridge counters unchanged |
| 5 | AI-block | ✅ PASS | E2E-BLOCK marker → mock allow:false → 403; `mvno_sms_blocked_total` ++; kamailio logs block |

**Defects found & fixed during the live debug (both verified empirically):**
1. **AI-filter mock never read chunked bodies** (docker-compose.yml): Spring/JDK
   `RestClient` sends `Transfer-Encoding: chunked` (no Content-Length); the inline
   mock only read `Content-Length` → always saw `b''` → every SMS allowed
   (`allow:true "Clean content"`), `mvno_sms_blocked_total` stayed 0. Fixed with a
   chunked-parsing branch in the mock's `do_POST`.
2. **Bridge 5G→2G reply malformed `Via: Via:`** (scripts/ip_sm_gw.py `reply_ok`):
   the relayed `Via` headers were kept whole and re-prefixed, producing invalid
   `Via: Via: SIP/2.0/UDP ...` in the 200 OK → Kamailio tm never matched the branch
   → unbounded retransmit storm (one 5G→2G SMS relayed/delivered ~9×). Fixed by
   stripping the prefix (`ln.strip().split(":",1)[1].strip()`); sender now receives
   its final 200 OK and each SMS is relayed exactly once.

**Design decisions (final):**
- IMS senders/receivers are **dedicated containers** on `mvno_mvno_net` with their
  own IP (10.89.0.54 recv / 10.89.0.55 send / 10.89.0.56 recv), running
  `scripts/testing/ims_terminal.py` (`--mode recv/send`), bypassing the UERANSIM
  5G user-plane — mirrors the proven Goal 6 receiver topology.
- 2G→5G rows are injected via `scripts/testing/inject_smsc_row.py` into
  `state/hlr/smsc.db` (the bridge's real polled `SMS` table, `deliver_attempts=0`).
- `send_db_sms.sh` (invented schema) and `send_vty_sms.sh` (VTY quirks) are NOT used.

---


Consolidated roadmap for the MVNO repo (`/home/zkhattab/AI-SpamFilter-PMN/MVNO`).
Teammate repos (`AI-Filteration-System`, `SipClient`, `sms-client`) are **read-only external** — integrate only, never edit.

## Dependency map
```
Goal 0 (freeze/baseline) ──▶ everything
Goal 4 (5G SMS) ─┐
Goal 5 (2G)     ─┼─ feature chain ─▶ Goal 6 (IP-SM-GW) ─▶ Goal 7 (e2e) ─▶ Goal 8 (obs/docs)
Goal 1 (portability) ── ✅ done; Goal 2 (scripts) ── ✅ done; Goal 3 (integration) ── ✅ done
```

## Goal 0 — Baseline & Working-Tree Freeze ✅ COMPLETE
- Freeze WIP → `8b44f29 chore: snapshot working-tree baseline`.
- **Fixed latent repro bug:** statically pinned ALL 27 services (`f057a77`) to prevent IPAM
  collision `10.89.0.4` on fresh-network creation (previously only mongodb pinned; unpinned
  services dynamically stole pinned IPs — the compose comment's own "static pin required" warning).
  **These pins are load-bearing — never unpin.**
- Live proof: **27/27 Up (0 unhealthy)**, `ran_ue=3`, api/actuator UP, ogstun N6 (rx=0/tx=240),
  counters 0/0→post-runbook 7/1, `kamailio -c` exit 0, `demo_runbook.sh` **ALL 13 PASSED**
  (incl. 5G user-plane traversal ogstun TX +2769 B). Recorded in `65bf520 docs(plan): Master
  Plan v6 + Goal 0 completion`.

## Goal 1 — Portability Hardening ✅ COMPLETE
- `e0c5db1`: Regen `scripts/bootstrap.sh` pins to match compose (mongo:7.0, vm/vmagent v1.147.0,
  kamailio 5.7.2, rtpengine mr9.4.0.0, vector 0.44.0-alpine, grafana 11.6.0) + add
  `percona/mongodb_exporter:0.41`; `podman image exists <exact-tag>` gate in `up.sh`;
  `scripts/load-offline.sh --verify-tags` (tarball tags vs compose pins; exit≠0 on drift);
  `scripts/preflight.sh`: compose plugin, sqlite3, nc, curl, tun, sctp module, multicast,
  `ss -lun | grep :5060` conflict (host Asterisk owns 5060; canonical = 5066).
- `a659a73`: Vector socket runtime-agnostic; relative-link sweep (absolute `file:///home/zkhattab`
  links → repo-relative); `docs/ENVIRONMENT_MATRIX.md`: amd64 Linux + rootless Podman only;
  macOS/arm64 unsupported.
- Open (deferred by decision): re-vendoring upstream tarballs (mongo 8.0 vs 7.0, `-latest`
  tags) — pins + `--verify-tags` gate accepted for this cycle; tracked in ISSUES.md.

## Goal 2 — Script Right-Sizing ✅ COMPLETE
- `a38041c`: `scripts/lib/common.sh` (detect_runtime/os/install_packages/try_log) shared by
  `vty.sh` + `seed-mongo.sh`; trim dead `scripts/testing/requirements.txt` (requests/smpplib
  unused — stdlib only); `make test` all suites pass.

## Goal 3 — Integration-Only ✅ COMPLETE (`5774214`)
- `docs/INTEGRATION_CONTRACT.md`: interfaces MVNO exposes (SIP 5066, SMPP 2775, REST
  `/api/v1/intercept/*` with `X-API-Key: mvno-demo-key-2026`, AI mock `:8000/api/v1/classify`);
  per-repo notes (SipClient 5060→5066 rec, sms-client `ai.classify.url=:5000` mismatch rec,
  `server.port=8080` overlap, AI-FS optional). §3 = optional env-gated `MVNO_PUBLISH_5060`
  (default-off; blocked here — Asterisk owns 5060) + §4 stability guarantee.
- `docker-compose.5060.yml`: extra `5060:5060/udp` publish, default-off, `preflight.sh`-gated.
- Gate: `podman compose config` parses with and without override; no absolute paths in doc.

## Goal 4 — Dual-Access SMS Phase 1 (5G/IMS SMS twin) ✅ COMPLETE (`add8130`)
- kamailio.cfg: top-level `OPTIONS→200`, top-level `CANCEL`, `MESSAGE` digest-auth →
  `route[INTERCEPT_SMS]` → `http_client_query` POST (4-arg; `http_client_post` not exported;
  JSON-escape `$rb` — strip quotes/newlines) → lookup → relay. SMS POST header string fixed
  (no trailing CRLF) so `curl_slist_append` emits headers then body.
- `scripts/testing/ims_terminal.py` deployed into ue-1 (10.45.0.2, :5091) / ue-2 (10.45.0.4, :5090);
  `_reply_ok` echoes ALL Via headers in order so tm matches the Kamailio-generated top branch.
- Gates PASSED: `kamailio -c` exit 0 → restart → runbook 5/5b/6 regression → MESSAGE delivered
  (digest) + printed on ue-2 → ogstun N6 TX delta>0 → `mvno_sms_requests_total` 4→6. debug=1 restored.

## Goal 5 — Dual-Access SMS Phase 2 (2G twin) ✅ COMPLETE
- New `mvno-2g-core`: apt `osmo-bsc` 1.14.1, `osmo-bts-virtual` 1.11.0, `osmo-stp` 2.2.1,
  `osmo-mgw` 1.15.0 (from verified-reachable osmocom Debian_12 repo — no source builds).
- New `mvno-2g-ms`: apt `osmocom-bb-layer23` + `osmocom-bb-virtphy` (0.2.0) → `mobile`+`virtphy`.
- Edit osmo-smsc.cfg adding `msc` A-interface node (SCCP/M3UA via STP) + built-in SC db; HLR
  provision 2G IMSIs. Keep SMPP ESME semantics.
- **Facts overruling older drafts:** binary is `osmo-msc` (package `osmo-msc`, not "osmo-smsc");
  `send_db_sms.sh` invented schema → DROP (decision); `send_vty_sms.sh` must use the real command.
- **MO-SMS routing:** `sms-over-gsup` is a kill-switch that DISABLES the built-in SMSC's local
  MO store&forward and forwards MO via HLR to an external SMSC GSUP entity — but osmo-msc's
  built-in SMSC has NO `MO_FORWARD_SM_REQUEST` rx handler and no separate `osmo-smsc` binary
  exists, so MO always failed (HLR ROUTING_ERROR). FIX: DO NOT enable `sms-over-gsup`; built-in
  SMSC handles MO locally (`gsm340_rx_sms_submit` → `sms_route_mt_sms` → store → MT).
- **Facts:** BTS is DCS1800 ARFCN 871 → mobile.cfg needs `stick 871` + `min-rxlev -110`
  (default GSM900 ARFCN 1 scan never camps). `sms-service-center 15550000000` required in
  mobile.cfg or MO is rejected ("SMS sms-service-center not defined"). Two UEs share the same
  GSMTAP multicast (many-to-many). MS1 IMSI …004/MSISDN 15554443322, MS2 IMSI …005/MSISDN 15557778888.
  MT assert = `cat /root/.osmocom/bb/sms.txt` inside handset container (needs
  `mkdir -p /root/.osmocom/bb && touch sms.txt`; missing file → RP-ERROR cause 22).
- Gates PASSED: BTS/BSC UP → both MS attached (MSC `show subscriber cache`) → **MO UE1→UE2 and
  UE2→UE1 delivered** (sms.txt) → SMPP MT delivered → `show sms-queue` pending 0 → telecom-api
  `/actuator/health` UP (no SMPP→telecom-api regression).

## Goal 6 — IP-SM-GW bridge ✅ COMPLETE
- `scripts/ip_sm_gw.py` (TS 23.204): 2G→5G (poll SC queue for non-2G recipients → Kamailio
  MESSAGE), 5G→2G (SIP SMS → `submit_sm`); MSISDN↔(UE, access) map from `subscriber` table.
- Gate: all 4 cross cells (2G→2G, 2G→5G, 5G→2G, 5G→5G) pass once.
- **Empirical Proof**:
  - Leg 1 (2G→5G): `15554443322` → `15551234567` (body 'GATE6 2Gto5G'). Bridge log: `POLL` → `SEND` → `DELIVERED`. Row `sent` marked in `smsc.db`.
  - Leg 2 (5G→2G): `15551234567` → `15554443322` (body 'GATE6 5Gto2G'). Bridge log: `[RELAY]` → `[SMPP] BIND_TRANSCEIVER OK` → `[SMPP] SUBMIT_SM OK`.
  - Bugfix A: `mark_attempt()` now called on failure; retries bounded to 5.
  - Bugfix B: tight `0.2s` recv loop removed; now uses `POLL_INTERVAL` (5s) to avoid Kamailio pike 429.

### Goal 6 design (empirically verified before coding)
- **Bridge runs as a container** `mvno-ip-sm-gw` on `mvno_net` (host has NO route to 10.89.0.0/24
  and containers have no route back to host published ports — verified `host:2775 FAIL` from
  kamailio), mounting `./state/hlr` for live read of `smsc.db`/`hlr.db` (osmo-hlr/osmo-smsc already
  share this volume → single source of truth) and `./scripts` for the bridge.
- **2G→5G leg (empirically proven)**: 2G MS→5G MSISDN MO SMS lands in SMSC queue as
  `SMS` row with `sent` NULL (verified: `MS1→15551234567` produced row id=17, `deliver_attempts=0`,
  osmo-msc log `Subscriber MSISDN-15551234567 is not attached, skipping SMS`). Bridge polls
  `smsc.db` `SMS` table for rows where `sent IS NULL AND dest_addr` is a 5G MSISDN → builds a
  digest-authenticated SIP MESSAGE (sender = 2G src, recipient = 5G dest) to Kamailio → Kamailio
  relays to registered 5G UE → bridge marks row delivered (`sent = now`).
- **5G→2G leg**: 5G UE sends SIP MESSAGE to a 2G MSISDN. Kamailio `lookup("location")` fails
  (2G MSISDN not a SIP location) → today returns 404. Bridge **REGISTERs** the 2G MSISDNs with
  Kamailio (Contact = its own SIP listener) so `lookup("location")` succeeds → Kamailio relays the
  MESSAGE to the bridge → bridge does SMPP `submit_sm` to osmo-smsc (SMSC MT-delivers to the 2G MS).
- **Subscriber access map** from `subscriber` table: 2G MSISDNs `15554443322` (MS1),
  `15557778888` (MS2); 5G MSISDNs `15551234567` (UE1), `15557654321` (UE2), `15559998888` (UE3).
  All 5 also present in Kamailio `subscriber` table (digest auth, password `testpass`).
- **SMPP ESME creds** reused from `send_smpp_sms.py` (BIND_TRANSCEIVER `smsclient`/`password`,
  osmo-smsc esme stanza `smsclient`/`password`), `submit_sm` PDU 0x00000004.
- Gate: run bridge, drive 2G→2G (MS1→MS2), 2G→5G (MS1→UE1), 5G→2G (UE1→MS1), 5G→5G (UE1→UE2);
  assert each destination receives the body, `sent` set for 2G→5G rows, `sms-queue` pending 0.

## Goal 7 — e2e_runbook.sh
- SIP-method × SMS-path × 4-cell matrix; deterministic AI-block (config-only mock rule —
  `allow:false` marker in the inline `mvno-ai-filter` mock, required because mock always
  returns `allow:true` today). Gate: exit 0 + per-leg asserts.

## Goal 8 — Observability & Docs
- New SMS counters; vector parse; Grafana 2G/5G panel; ISSUES/ROADMAP/README/ENVIRONMENT_MATRIX.

## Open decisions (defaults applied — revisit only on user request)
1. Re-vendor upstream tarballs (mongo 8.0 vs 7.0, `-latest` tags): **DEFER**; pins + `--verify-tags`.
2. `send_db_sms.sh` (invented schema): **DROP**.
3. Goal 7 AI-block: config-only mock edit: **ACCEPTED**.
4. 2G MT assert: container logs on handset container: **ACCEPTED**.
5. Commit order: Goal 3 → 4 → 5 (checkpoint) → 6 → 7 → 8.

---

# HISTORICAL RECORD (prior to Plan v6 — superseded by v7; retained verbatim) — Phase 0 / 1 / 2

## Phase 0 — 5G SA User-Plane Data Gate & Documentation (COMPLETED)

## Problem
Phase 0 data-plane gate: prove UL + DL user plane end-to-end (UE tun → N3 GTP-U → UPF → N6 ogstun)
across the containerized 5G SA core, then document all issues/fixes/gotchas.

## Root Causes Found & Fixed
1. **ogstun gateway never configured** — `ogs_tun_set_ip()` in `lib/tun/linux-setup.c` is a
   **no-op returning OGS_OK** on Linux (verified identical in v2.7.7 and v2.8.0;
   `src/upf/gtp-path.c:1013` "Note that Linux will skip this configuration"). Kernel dropped
   every packet written to ogstun (no route into 10.45.0.0/16).
   **Fix**: `configs/open5gs/entrypoint.sh` UPF branch polls for `ogstun` then applies
   `ip addr replace 10.45.0.1/16 dev ogstun` (+ IPv6 `2001:db8:cafe::1/48`, link up);
   `configs/open5gs/Dockerfile` adds `iproute2`.
2. **Fresh v2.8.0 source rebuild regresses SBI HTTP/2 client** — every NF died at first
   heartbeat: `Error in the HTTP2 framing layer (16)` (lib/sbi/client.c:767) → NRF
   de-registration. 2×2 image matrix proved only new-image *clients* fail.
   **Fix**: Dockerfile layered on known-good `mvno-open5gs:latest` (a2f041bbd267) — only
   `iproute2` + entrypoint; never rebuild from source (banner in Dockerfile).
3. **SMF UE pool could allocate the ogstun gateway .1 to a UE** (wave 1: ue-2 = 10.45.0.1).
   **Fix**: `configs/open5gs/smf.yaml` session: `gateway: 10.45.0.1` + `range: 10.45.0.2-10.45.0.254`.
4. **UL dead after partial gNB recreate** — stale NGAP contexts; UERANSIM gNB silently
   swallows PDU Session Resource Setup (`findUeByNgapIdPair` null, session.cpp) → no RRC
   Reconfiguration/DRB → no data radio.
   **Fix (rule)**: always recreate the whole UERANSIM trio atomically.
5. **ue-1-only quirk**: second PDU Session Establishment ~10 s post-recreate → SMF
   `Unknown message [214]` + HTTP 400 → session teardown. Fix: recreate that UE.

## Changes Applied
- `configs/open5gs/entrypoint.sh`, `configs/open5gs/Dockerfile`, `configs/open5gs/smf.yaml`,
  `configs/open5gs/upf.yaml` (logger trace reverted to default), `configs/ueransim/gnb.yaml` +
  `configs/ueransim/ue.yaml` (temp debug reverted), `docker-compose.yml` (IP pinning).
- Docs: `docs/ISSUES.md` (new: 5.5, 5.6, 5.7, 7.3, 7.4, 8.18, 8.19 + 4 checklist rows),
  `docs/deployment_guide.md` (Step 6: 5G SA data path), `docs/implementation_guide.md`
  (troubleshooting rows + Phase 0 debug loop + smf.yaml range snippet), `ONBOARDING.md`.

## Verification (stopping assertion — all PASS)
- `podman exec mvno-upf ip addr show ogstun` → `inet 10.45.0.1/16`, `UP`.
- UL: 5 UDP probes ue-1 tun → 10.45.0.1:9 → UPF `[RECV] GPU-U Type [255] from [10.89.0.30] :
  TEID[0x9fa2]`; ogstun RX +165 B (last live: 859 B / 21 pkts).
- DL: 4 UDP probes from UPF netns → ue-1 tun:9 → ue tun RX incremented.
- Pool: UE addresses in .2-.254 (never .1); 27/27 containers Up; 0 HTTP2 framings post-settle;
  0 NRF de-registrations.
- `make test` exit 0; `podman compose config -q` OK.

## Rollback
Revert entrypoint/Dockerfile/smf.yaml; rebuild image. No data touched.
Docs edits are additive only.

## Next Phase (Phase 1 — COMPLETED)
Phase 1: SIP-over-5G proven end-to-end. Same simulator drives both paths (flexible):
- `sip_traffic_sim.py` parameterized (`--host/--port/--caller/--callee/--password`, defaults =
  127.0.0.1:5066 preserve the 2G/IMS behavior exactly).
- Rootless finding: host route to 10.45.0.0/16 is **impossible** (podman keeps 10.89.0.0/24 in
  its user netns) → UPF-internal SNAT instead (Issue 8.20): idempotent MASQUERADE rule in
  `configs/open5gs/entrypoint.sh`; `iptables` layered into the Open5GS image; `python3` baked
  into the UERANSIM runner stage.
- Per-UE steering: `ip route replace 10.89.0.23/32 dev uesimtun0` (kamailio only; the UE's
  `10.89.0.0/24 dev eth0` route keeps gNB/control traffic off the 5G path).
- Gate PASSED (live): from ue-1 via the 5G plane — REGISTER 200 OK, INVITE 407→digest→100
  trying; ogstun ~10KB RX/~15KB TX per dialog; `mvno_call_requests_total` increments;
  Kamailio usrloc shows the 5G-registered callee. 2G/IMS path regression PASS.
- Warm-up note: first packet after a UPF/bridge restart may race neighbor resolution → re-run.

## Phase 2 (demo_runbook.sh — COMPLETED)
Runbook item 5 extended with the 5G-path block (5b): UE route replace, podman cp the sim,
assert REGISTER 200 OK + INVITE response + ogstun RX delta. 2G/IMS items untouched.
Docs: deployment guide Step 7 (flexible dual-path table), ISSUES.md §8.20 + Phase 1 checklist
row, implementation guide rows, ONBOARDING rows.
