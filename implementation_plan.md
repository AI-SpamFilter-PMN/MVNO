# Implementation Plan: Phase 0 — 5G SA User-Plane Data Gate & Documentation

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
