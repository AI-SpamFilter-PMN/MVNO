# Implementation Plan — Master Plan v7 (Goals 0–5 ✅ COMPLETE; Goal 6 NEXT)

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

## Goal 6 — IP-SM-GW bridge
- `scripts/ip_sm_gw.py` (TS 23.204): 2G→5G (poll SC queue for non-2G recipients → Kamailio
  MESSAGE), 5G→2G (SIP SMS → `submit_sm`); MSISDN↔(UE, access) map from `subscriber` table.
- Gate: all 4 cross cells (2G→2G, 2G→5G, 5G→2G, 5G→5G) pass once.

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
