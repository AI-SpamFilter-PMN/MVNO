# MVNO Core — Architectural & Operational Roadmap (`docs/ROADMAP.md`)

This document outlines upcoming architectural enhancements, operational backlog items, security hardening notes, and subsystem evaluations for the **MVNO Cellular Core** infrastructure.

---

## 1. Architectural Enhancements

### 1. SIP INVITE Digest Authentication (407 Challenge)
- **Current State**: Kamailio challenges `REGISTER` requests via `auth_check()`. `INVITE` requests currently pass directly to `route(INTERCEPT)` without authentication challenge (`$au` is `""`).
- **Roadmap Item**: Implement `407 Proxy Authentication Required` challenge flow for SIP `INVITE` requests using `auth_check()`.
- **Interop Client**: Compatible with `SipClient`'s `InviteAuthenticator` module.

### 2. Gateway API Key Authentication
- **Current State**: `telecom-api` REST endpoints (`/api/v1/intercept/*`) process requests without API key headers.
- **Roadmap Item**: Implement `X-API-Key` HTTP header authentication and rate-limiting middleware for carrier API gateways.

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

- [ ] **Remote Branch Cleanup**: Delete 8 merged feature branches on `origin` (`feature/5g-core-open5gs`, `feature/telecom-gateway-api`, etc.).
- [ ] **Orphaned State File Cleanup**: Create automated cleanup utility for orphaned temporary database lock files (`*.db-shm`, `*.db-wal`) in `./state/`.
- [ ] **VictoriaMetrics Self-Scrape Job**: Add `victoria-metrics` (`victoria-metrics:8428/metrics`) scrape job to `configs/victoria-metrics/scrape.yml` to collect `vm_*` internal TSDB metrics and `vmagent_remotewrite_*` pipeline stats.
- [ ] **VictoriaMetrics System NOC Dashboard**: Create `noc_victoriametrics.json` Grafana dashboard (cache entries, ingestion rate `vm_rows_added_total`, disk usage `vm_fsdata_bytes`, `vmagent` remoteWrite stats).
- [ ] **vmagent RemoteWrite Alert Panel**: Add a `vmagent_remotewrite_blocks_failed_total` alerting panel to `noc_overview.json` to make telemetry write failures immediately visible at a glance.
- [ ] **Kamailio JSON-Regex Hardening (F13)**: Hardening SIP body regex parsing in Kamailio routing script for multi-part boundary headers.
- [ ] **Open5GS UDM `no_tls` Evaluation**: Verify UDM HTTP/2 cleartext framing settings against 3GPP Rel-16 specs.
- [ ] **Kamailio `jsonrpcs` Evaluation**: Evaluate Kamailio `jsonrpcs` management interface for live NOC runtime stats.

---

## 3. Security Notes & Warnings

> [!WARNING]
> **Unauthenticated MongoDB Host Port Exposure**: Port `27017` is published locally for Open5GS WebUI and debugging without authentication enabled. Production deployments must enforce MongoDB authentication (`security.authorization: enabled`) and restrict host port bindings.
