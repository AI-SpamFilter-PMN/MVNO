# MVNO Core — Architectural & Operational Roadmap (`docs/ROADMAP.md`)

> Abbreviations: **docs/GLOSSARY.md** — single source of truth
This document outlines upcoming architectural enhancements, operational backlog items, security hardening notes, and subsystem evaluations for the **MVNO Cellular Core** infrastructure.

---

## 1. Architectural Enhancements

### 1. SIP INVITE Digest Authentication (407 Challenge) — ✅ IMPLEMENTED
- **Current State**: Kamailio challenges both `REGISTER` and `INVITE` via `auth_check()` (commit `7b33ac1`). Unauthenticated `INVITE` → `407 Proxy Authentication Required`; authenticated zero-balance callers still receive `403 Call Intercepted / Blocked` from `route(INTERCEPT)`. Digest realm `localhost`, credentials from the SQLite `subscriber` table.
- **Verification**: `scripts/testing/sip_traffic_sim.py` (REGISTER + digest-authenticated INVITE) and runbook step 6 (407 → digest → 403 handshake) both green.
- **Interop Client**: Compatible with `SipClient`'s `InviteAuthenticator` module (see `docs/INTEGRATION_CONTRACT.md` Section 5 SipClient — 407 digest handling).

### 2. Gateway API Key Authentication — ✅ IMPLEMENTED
- **Current State**: `telecom-api` enforces `X-API-Key` on all `/api/v1/intercept/**` endpoints via `ApiKeyInterceptor` (commit `0590aac`). Missing/mismatched key → `401 Unauthorized`. Key from `intercept.api-key` property (`X_API_KEY` env override, demo default `mvno-demo-key-2026`); Kamailio INTERCEPT queries carry the header via 4-arg `http_client_query`.
- **Verification**: unit tests (3 interceptor cases, 26/26 total), Makefile + runbook curls all carry the header; no-header → 401 confirmed live.

### 3. VictoriaLogs Log Ingestion Sink
- **Current State**: Vector outputs JSON logs to `[sinks.stdout]`.
- **Roadmap Item**: Add `[sinks.victorialogs]` HTTP ingestion sink targeting `victorialogs:9428` for long-term log archiving and Grafana log queries.

### 3b. Real-Call Recording → ASR Transcription Pipeline (pcap→wav→Vosk) — ✅ IMPLEMENTED
- **Current State**: rtpengine mr9.4 records calls as `recording-format=eth` pcaps only (no WAV support in this build); `record-call=yes` produces pcaps while the Vosk watcher consumed `.wav` — real calls were never transcribed.
- **Implementation**: `scripts/testing/live_tap.sh` (tshark → awk → xxd → ffmpeg, zero Python) decodes G.711 PCMU RTP per source-IP leg (RTCP odd ports dropped, 12-byte RTP header stripped) into 8 kHz WAVs in `state/spool/`, where `NativeVoskService` polls every 3 s, transcribes, and archives `.wav` + `.txt`. Two modes: `--once` post-call extraction (Tier-3 fallback, replaces the retired `pcap_to_wav.py`) and a `daemon` watcher that incrementally chunks the growing pcap into `live-*.wav` for mid-call (Tier-1) transcription. Verified end-to-end on a real call (Issue 8.27; see `docs/REALTIME_AUDIO.md`).
- **Usage**: `scripts/testing/live_tap.sh --once state/spool/pcaps/call-*.pcap` (or `live_tap.sh daemon` for Tier-1 live chunks)
- **Roadmap Item**: ✅ Implemented — the `daemon` mode auto-watches the pcaps dir (1 s poll, 4 s chunks); optional tuning documented in `docs/REALTIME_AUDIO.md` (poll timings, kernel-proc route).

### 4. Container Native Healthcheck Endpoints
- **Current State**: Container healthchecks use CLI tools (`mongosh`, `curl`).
- **Roadmap Item**: Expose `/actuator/health` and `/healthz` HTTP healthcheck endpoints across all custom microservices.

### 5. Open5GS SBI Advertisement Evaluation
- **Current State**: Service advertisement parameters (`advertise: <hostname>`) in Open5GS NF YAML configs are maintained in committed `main`.
- **Roadmap Item**: Perform test-driven evaluation of SBI advertisement parameters with NRF registration tests across custom bridge networks.

---

## 2. Operational Backlog & Housekeeping

- [ ] **Remote Branch Cleanup**: Delete 8 merged feature branches on `origin` (`feature/5g-core-open5gs`, `feature/telecom-gateway-api`, etc.). — **INTENTIONALLY KEPT** (user decision, Aug 1 2026): all 9 local + 8 remote branches are fully merged into `main` and retained as frozen domain evidence for the graduation portfolio. No deletions, no prunes.
- [x] **Orphaned State File Cleanup**: ~~Added `scripts/cleanup-state.sh` — removes stale `*.db-shm` / `*.db-wal` lock files in `./state/` only when the owning container (hlr/kamailio/grafana) is not running; `-n` dry-run flag; live files always skipped.~~ **REMOVED** (Aug 7 2026): script was never referenced by any runbook or systemd unit; SQLite/PG lock files are owned and cleaned by their containers (WAL auto-checkpoint). Strikethrough retained for portfolio transparency.
- [x] **VictoriaMetrics Self-Scrape Job**: Add `victoria-metrics` (`victoria-metrics:8428/metrics`) scrape job to `configs/victoria-metrics/scrape.yml` to collect `vm_*` internal TSDB metrics and `vmagent_remotewrite_*` pipeline stats.
- [x] **VictoriaMetrics System NOC Dashboard**: Created `noc_victoriametrics.json` Grafana dashboard (cache entries, ingestion rate `rate(vm_rows_added_to_storage_total[5m])`, disk usage `vm_data_size_bytes` / `vm_free_disk_space_bytes`, `vmagent` remoteWrite stats).
- [x] **vmagent RemoteWrite Alert Panels**: Added `vmagent_remotewrite_blocks_sent_total` / `vmagent_remotewrite_errors_total` / `vmagent_remotewrite_push_failures_total` panels to `noc_victoriametrics.json` to make telemetry write failures immediately visible at a glance.
- [ ] **Kamailio JSON-Response Parsing Hardening (F13)**: Replace regex `allow:false` matching on the gateway HTTP response (`kamailio.cfg` `route[INTERCEPT]`, `$var(res_body) =~ ".*\"allow\"[[:space:]]*:...false.*"`) with structured jansson `json_get_field()` parsing for reliable interception decisions. (Backlog — avoid touching the working interception path near demo day; current regex verified working live.)
- [x] **Open5GS UDM `no_tls` Evaluation**: Verified `no_tls: true` HTTP/2 cleartext (h2c) SBI framing in `udm.yaml` (and all NF configs: amf/ausf/bsf/nrf/nssf/pcf/smf/udr; UPF exempt — PFCP, no SBI) against 3GPP Rel-16 TS 29.500/29.501 — see `docs/ISSUES.md` Issue 5.4.
- [ ] **Kamailio `jsonrpcs` Evaluation**: Evaluate Kamailio `jsonrpcs` management interface for live NOC runtime stats.

---

## 3. Security Notes & Warnings

> [!WARNING]
> **Unauthenticated MongoDB Host Port Exposure**: Port `27017` is published on the loopback interface only (`127.0.0.1:27017` in `docker-compose.yml`) for Open5GS WebUI and debugging without authentication enabled. Production deployments must enforce MongoDB authentication (`security.authorization: enabled`).
