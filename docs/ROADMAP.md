# MVNO Core — Architectural & Operational Roadmap (`docs/ROADMAP.md`)

This document outlines upcoming architectural enhancements, operational backlog items, security hardening notes, and subsystem evaluations for the **MVNO Cellular Core** infrastructure.

---

## 1. Architectural Enhancements

### 1. SIP INVITE Digest Authentication (407 Challenge) — ✅ IMPLEMENTED
- **Current State**: Kamailio challenges both `REGISTER` and `INVITE` via `auth_check()` (commit `7829d5a`). Unauthenticated `INVITE` → `407 Proxy Authentication Required`; authenticated zero-balance callers still receive `403 Call Intercepted / Blocked` from `route(INTERCEPT)`. Digest realm `localhost`, credentials from the SQLite `subscriber` table.
- **Verification**: `scripts/testing/sip_traffic_sim.py` (REGISTER + digest-authenticated INVITE) and runbook step 6 (407 → digest → 403 handshake) both green.
- **Interop Client**: Compatible with `SipClient`'s `InviteAuthenticator` module (see `docs/API_CONTRACT.md` §3.3).

### 2. Gateway API Key Authentication — ✅ IMPLEMENTED
- **Current State**: `telecom-api` enforces `X-API-Key` on all `/api/v1/intercept/**` endpoints via `ApiKeyInterceptor` (commit `fc1c006`). Missing/mismatched key → `401 Unauthorized`. Key from `intercept.api-key` property (`X_API_KEY` env override, demo default `mvno-demo-key-2026`); Kamailio INTERCEPT queries carry the header via 4-arg `http_client_query`.
- **Verification**: unit tests (3 interceptor cases, 22/22 total), Makefile + runbook curls all carry the header; no-header → 401 confirmed live.

### 3. VictoriaLogs Log Ingestion Sink
- **Current State**: Vector outputs JSON logs to `[sinks.stdout]`.
- **Roadmap Item**: Add `[sinks.victorialogs]` HTTP ingestion sink targeting `victorialogs:9428` for long-term log archiving and Grafana log queries.

### 4. Container Native Healthcheck Endpoints
- **Current State**: Container healthchecks use CLI tools (`mongosh`, `curl`).
- **Roadmap Item**: Expose `/actuator/health` and `/healthz` HTTP healthcheck endpoints across all custom microservices.

### 5. Open5GS SBI Advertisement Evaluation
- **Current State**: Service advertisement parameters (`advertise: <hostname>`) in Open5GS NF YAML configs are maintained in committed `main`.
- **Roadmap Item**: Perform test-driven evaluation of SBI advertisement parameters with NRF registration tests across custom bridge networks.

---

## 2. Operational Backlog & Housekeeping

- [ ] **Remote Branch Cleanup**: Delete 8 merged feature branches on `origin` (`feature/5g-core-open5gs`, `feature/telecom-gateway-api`, etc.). — **INTENTIONALLY KEPT** (user decision, Aug 1 2026): all 9 local + 8 remote branches are fully merged into `main` and retained as frozen domain evidence for the graduation portfolio. No deletions, no prunes.
- [ ] **Orphaned State File Cleanup**: Create automated cleanup utility for orphaned temporary database lock files (`*.db-shm`, `*.db-wal`) in `./state/`.
- [x] **VictoriaMetrics Self-Scrape Job**: Add `victoria-metrics` (`victoria-metrics:8428/metrics`) scrape job to `configs/victoria-metrics/scrape.yml` to collect `vm_*` internal TSDB metrics and `vmagent_remotewrite_*` pipeline stats.
- [ ] **VictoriaMetrics System NOC Dashboard**: Create `noc_victoriametrics.json` Grafana dashboard (cache entries, ingestion rate `vm_rows_added_total`, disk usage `vm_fsdata_bytes`, `vmagent` remoteWrite stats).
- [ ] **vmagent RemoteWrite Alert Panel**: Add a `vmagent_remotewrite_blocks_failed_total` alerting panel to `noc_overview.json` to make telemetry write failures immediately visible at a glance.
- [ ] **Kamailio JSON-Regex Hardening (F13)**: Hardening SIP body regex parsing in Kamailio routing script for multi-part boundary headers.
- [ ] **Open5GS UDM `no_tls` Evaluation**: Verify UDM HTTP/2 cleartext framing settings against 3GPP Rel-16 specs.
- [ ] **Kamailio `jsonrpcs` Evaluation**: Evaluate Kamailio `jsonrpcs` management interface for live NOC runtime stats.

---

## 3. Security Notes & Warnings

> [!WARNING]
> **Unauthenticated MongoDB Host Port Exposure**: Port `27017` is published on the loopback interface only (`127.0.0.1:27017` in `docker-compose.yml`) for Open5GS WebUI and debugging without authentication enabled. Production deployments must enforce MongoDB authentication (`security.authorization: enabled`).
