# Implementation Plan — MVNO Core with AI Spam Filter Integration

This document outlines the design and step-by-step implementation plan for the MVNO network core, call recording/transcription plane, and the REST API integration with the AI Filtration System.

---

## User Review Required

> [!IMPORTANT]
> **1. Podman Rootless Socket Mapping**
> While port 5060 is > 1024 and does not require system modifications, if your local network environment blocks unprivileged traffic mapping, we may need to temporarily bind clients to a high port (e.g., `55060` for SIP or `52775` for SMPP) during sandbox testing.
>
> **2. Vosk CPU Overhead**
> Vosk is highly optimized, but running offline speech recognition on an 8GB RAM host machine during a call can cause brief CPU spikes. We will restrict the Vosk thread pool to 2 cores inside the container/systemd settings.
>
> **3. SQLite Concurrency (WAL Mode)**
> SQLite handles high concurrency through Write-Ahead Logging (WAL). This will be configured as the default on both Kamailio and Osmocom databases to prevent locking conflicts when the AI filtration system performs read scans during writes.

---

## Open Questions

> [!WARNING]
> **1. Call Interception Flow Preference**
> For suspected voice call spam, should the call:
> - **A (Real-time Blocking):** Be held in an active state while Vosk transcribes the first few seconds of audio, then blocked immediately if spam? (Introduces a 3-5 second caller lag).
> - **B (Post-Call Logging & Quarantine):** Be allowed to proceed, recorded in full, and processed post-call to update the blacklist for future calls?
> _Currently, this plan assumes **Option B** (Post-Call Quarantine) to avoid breaking real-time voice latency requirements, but can be adapted._

---

## Proposed Changes

We will organize the implementation into independent, modular sectors.

```
/home/zkhattab/MVNO/
├── .agents/
│   └── AGENTS.md                  # Workspace rules (already created)
├── configs/
│   ├── kamailio/
│   │   ├── kamailio.cfg           # SIP routing and rtpengine logic
│   │   └── kamctlrc               # Database configuration helper
│   ├── osmocom/
│   │   └── osmo-smsc.cfg          # SMSC rate limits and SMPP configs
│   ├── rtpengine/
│   │   └── rtpengine.conf         # Media plane port ranges and recording settings
│   └── victoria-metrics/
│       └── scrape.yml             # vmagent target endpoints
├── telecom-api/
│   ├── main.py                    # FastAPI server for interception APIs
│   ├── requirements.txt           # Python dependencies (fastapi, uvicorn, redis)
│   └── Dockerfile                 # Multi-stage lightweight python container
├── telecom-data-pipeline/
│   ├── vector.toml                # Vector log routing and parsing config
│   ├── vosk_worker.py             # Spawns Vosk STT on recorded call audio
│   └── requirements.txt           # Python deps (vosk, soundfile, requests)
├── docker-compose.yml             # Unified rootless container stack
└── Makefile                       # Developer command interface
```

---

### [Component 1] Infrastructure & Orchestration

#### [NEW] [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml)
Define the unified stack with explicit dependency sequencing and rootless parameters:
- Use SELinux volume flags (`:z`) for configuration directories.
- Inject `.env` for system passwords and IPs.
- Limit MongoDB resources (`--wiredTigerCacheSizeGB 0.25`).
- Bind containers to custom bridge network `mvno_net`.

#### [NEW] [Makefile](file:///home/zkhattab/MVNO/Makefile)
Provide zero-overhead shortcut commands for lifecycle tasks:
- `make up`: Starts containers with `restart: "no"` parameters.
- `make down`: Gracefully stops all services.
- `make test-sms`: Triggers mock SMPP traffic to verify routing.
- `make test-call`: Executes a mock SIP call via `sipp` to verify RTP routing.

---

### [Component 2] Telecom Network Core (SIPS & SMSC)

#### [NEW] [osmo-smsc.cfg](file:///home/zkhattab/MVNO/configs/osmocom/osmo-smsc.cfg)
Configure the Osmocom Short Message Service Centre:
- Enforce SMPP TLS parameters.
- Set per-ESME rate limits to defend against message floods.
- Route logs to a dedicated file (`/var/log/osmocom/osmo-smsc.log`) for real-time tailing.

#### [NEW] [kamailio.cfg](file:///home/zkhattab/MVNO/configs/kamailio/kamailio.cfg)
Configure Kamailio as the IMS Call Session Control Function (CSCF):
- Enable the `db_sqlite` module for registering subscriber contacts.
- Load the `rtpengine` module and redirect incoming media streams to rtpengine for routing and recording.
- Integrate the `pike` and `htable` modules at the top of the routing script to block suspicious IPs.
- Forward call registration events to the FastAPI local endpoint.

#### [NEW] [rtpengine.conf](file:///home/zkhattab/MVNO/configs/rtpengine/rtpengine.conf)
Configure rtpengine for media plane handling:
- Specify UDP port ranges above `1024` for RTP media relay.
- Enable call recording with file storage pointed to a shared directory `/var/spool/rtpengine`.
- Output audio metadata in `.json` format for the data pipeline.

---

### [Component 3] REST API Interception Gateway

#### [NEW] [main.py](file:///home/zkhattab/MVNO/telecom-api/main.py)
Provide the async FastAPI implementation:
- **`POST /api/v1/intercept/sms`**: Receives SMS data from OsmoSMSC. Validates payload and requests classification from the AI Spam Filter REST API. Returns `allow: true/false`.
- **`POST /api/v1/intercept/call`**: Receives SIP INVITE events from Kamailio. Performs quick blacklist validation and updates active session tables.
- **`GET /live`** and **`GET /ready`**: Lightweight async health-check endpoints.

#### [NEW] [requirements.txt](file:///home/zkhattab/MVNO/telecom-api/requirements.txt)
Define direct runtime dependencies:
- `fastapi`
- `uvicorn`
- `pydantic`
- `requests`

---

### [Component 4] Media Translation & Observability Pipeline

#### [NEW] [vosk_worker.py](file:///home/zkhattab/MVNO/telecom-data-pipeline/vosk_worker.py)
Implement the offline speech-to-text pipeline:
- Monitor the shared recording directory `/var/spool/rtpengine` for newly completed audio files.
- Read files using `vosk` offline model.
- Transcribe audio to text and POST the raw transcript to the AI Filtration system's REST API.

#### [NEW] [vector.toml](file:///home/zkhattab/MVNO/telecom-data-pipeline/vector.toml)
Configure Vector for Rust-based log parsing:
- Tail `/var/log/kamailio/kamailio.log` and `/var/log/osmocom/osmo-smsc.log`.
- Parse out registration events and plaintext IMSI warnings using Vector Remap Language (VRL).
- Post events to the FastAPI local router.

#### [NEW] [scrape.yml](file:///home/zkhattab/MVNO/configs/victoria-metrics/scrape.yml)
Set up `vmagent` scraping profiles:
- Collect metrics from Kamailio prometheus endpoints.
- Collect metrics from `rtpengine` statistics socket.
- Scraping target: `/var/run/vm-metrics`.

---

## Verification Plan

### Automated Tests
*   **SIP Call Simulation (`make test-call`)**: Run `sipp` to establish a call, verify that `rtpengine` records the audio, and check that `vosk_worker.py` successfully transcribes it.
*   **SMS Delivery (`make test-sms`)**: Run a mock python SMPP script to send an SMS, validating that it triggers the `/api/v1/intercept/sms` endpoint and logs the AI decision.
*   **API Probing**: Validate that `curl http://localhost:8080/ready` returns a `200` status with green metrics.

### Manual Verification
*   Deploy the container stack under rootless Podman and verify with `podman ps` that all volumes mount correctly without SELinux denials.
*   Review Grafana dashboards (`http://localhost:3000`) to confirm that time-series data shows metrics flowing from VictoriaMetrics.
