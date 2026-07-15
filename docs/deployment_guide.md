# Deployment and Configuration Guide — MVNO Core

This guide covers the transaction flow, software prerequisites, and complete configuration files for deploying the MVNO Core using both the **Native (systemd)** and **Containerized (Podman-compose)** methods.

---

## 1. Project Transaction Flow & Steps

![MVNO Core Flow Chart](architecture_flow.svg)

### Voice Transaction Steps:
1. **SIP Invite**: `UE_1` sends an `INVITE` request to Kamailio.
2. **Media Path Setup**: Kamailio proxies the signaling, registers the call location in the SQLite database, and calls `rtpengine` to bind media ports.
3. **Media Forking**: When the call starts, `rtpengine` forwards the media (RTP streams) between clients in-kernel and forks a raw copy of the audio to the spool directory `/var/spool/rtpengine`.
4. **Offline Translation**: The `vosk_worker.py` script detects the finished audio files, transcribes them using the local Vosk model, and sends the transcript to the FastAPI Gateway.
5. **AI Filtration Check**: The FastAPI Gateway queries the external AI Filtration System's REST API. If the call contains spam, the number is blacklisted.

### SMS Transaction Steps:
1. **SMS Submit**: The SMS Client sends an SMS via SMPP to `OsmoSMSC`.
2. **Hold & Verification**: `OsmoSMSC` holds delivery and calls the FastAPI Gateway's `/api/v1/intercept/sms` endpoint.
3. **AI Check & Delivery**: FastAPI forwards the content to the AI Filtration system. If approved, `allow: true` is returned and `OsmoSMSC` delivers the message. If spam, it is dropped.

---

## 2. Software Prerequisites

### Method A: Native (systemd)
Deploying directly onto a Debian-slim/Ubuntu 22.04 LTS host:

| Component | Package / Source | Command to Install |
| :--- | :--- | :--- |
| **Kamailio** | Debian/Ubuntu packages | `sudo apt install kamailio kamailio-sqlite-modules` |
| **rtpengine** | Packages / Source | `sudo apt install ngcp-rtpengine ngcp-rtpengine-daemon` |
| **Osmocom** | Osmocom OBS repositories | `sudo apt install osmo-msc osmo-hlr` |
| **Vosk STT** | Python / Pip library | `pip install vosk soundfile requests` |
| **FastAPI** | Python / Pip library | `pip install fastapi uvicorn requests` |
| **Vector** | Vector deb repo | `sudo apt install vector` |
| **VictoriaMetrics**| Pre-compiled binary | Download from GitHub releases |
| **Grafana** | Grafana APT repo | `sudo apt install grafana` |

### Method B: Containerized (Podman-compose)
Operating in a daemonless, rootless environment:

| Tool | Version / Source | Why |
| :--- | :--- | :--- |
| **Podman** | `sudo apt install podman` | Daemonless rootless engine |
| **Podman Compose**| `sudo apt install podman-compose` | Alternative to docker-compose |
| **Kamailio Image** | `kamailio/kamailio:5.7-alpine` | Lightweight Alpine-based container |
| **rtpengine Image**| `ngcp/rtpengine:latest` | Standard media engine container |
| **Osmocom Images** | `osmocom/osmo-msc-latest` | Official Osmocom containers |
| **Vosk Image** | `python:3.11-slim` (Custom) | Python model host container |
| **FastAPI Image** | `python:3.11-alpine` (Custom) | Minimal API gateway container |
| **VictoriaMetrics**| `victoriametrics/victoria-metrics` | Single-node database container |
| **Grafana Image** | `grafana/grafana-oss` | Metric UI dashboard container |

---

## 3. Configuration Profiles

### A. Native (systemd) Configuration Profiles

#### 1. Kamailio Systemd Unit (`/etc/systemd/system/kamailio.service`)
```ini
[Unit]
Description=Kamailio SIP Server
After=network.target rtpengine.service

[Service]
Type=forking
User=kamailio
Group=kamailio
PIDFile=/run/kamailio/kamailio.pid
ExecStart=/usr/sbin/kamailio -f /etc/kamailio/kamailio.cfg -P /run/kamailio/kamailio.pid
Restart=no

[Install]
WantedBy=multi-user.target
```

#### 2. rtpengine Systemd Unit (`/etc/systemd/system/rtpengine.service`)
```ini
[Unit]
Description=rtpengine Media Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/rtpengine --config-file=/etc/rtpengine/rtpengine.conf
User=rtpengine
Group=rtpengine
Restart=no

[Install]
WantedBy=multi-user.target
```

---

### B. Containerized (Podman-compose) Configuration Profiles

The `docker-compose.yml` is configured for **rootless Podman** execution:
- Host port mappings are above `1024` to prevent permission errors.
- SELinux contexts are dynamically modified using `:z` volume flags.
- Databases use strict RAM caps suitable for unprivileged execution.

#### [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml)
```yaml
version: "3.8"

networks:
  mvno_net:
    driver: bridge

services:
  # 1. Database (Open5GS Metadata / Analytics)
  mongodb:
    image: mongo:8.0
    container_name: mvno-mongodb
    command: mongod --wiredTigerCacheSizeGB 0.25
    ports:
      - "27017:27017"
    volumes:
      - ./state/mongodb:/data/db:z
    networks:
      - mvno_net
    restart: "no"

  # 2. SIP Media Relay
  rtpengine:
    image: ngcp/rtpengine:latest
    container_name: mvno-rtpengine
    ports:
      - "30000-30100:30000-30100/udp"
    volumes:
      - ./configs/rtpengine:/etc/rtpengine:z
      - ./state/spool:/var/spool/rtpengine:z
    networks:
      - mvno_net
    restart: "no"

  # 3. SIP Signaling Proxy
  kamailio:
    image: kamailio/kamailio:5.7-alpine
    container_name: mvno-kamailio
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
    volumes:
      - ./configs/kamailio:/etc/kamailio:z
    depends_on:
      - rtpengine
    networks:
      - mvno_net
    restart: "no"

  # 4. SMS Centre
  osmo-smsc:
    image: osmocom/osmo-msc-latest
    container_name: mvno-osmosmsc
    ports:
      - "2775:2775"
    volumes:
      - ./configs/osmocom:/etc/osmocom:z
    networks:
      - mvno_net
    restart: "no"

  # 5. FastAPI Interception Gateway
  telecom-api:
    build:
      context: ./telecom-api
    container_name: mvno-api
    ports:
      - "8080:8080"
    volumes:
      - ./configs/kamailio:/etc/kamailio:z
    networks:
      - mvno_net
    restart: "no"

  # 6. Observability Database
  victoria-metrics:
    image: victoriametrics/victoria-metrics:latest
    container_name: mvno-victoriametrics
    ports:
      - "8428:8428"
    volumes:
      - ./state/vm-data:/victoria-metrics-data:z
    networks:
      - mvno_net
    restart: "no"

  # 7. Metrics Collection Agent
  vmagent:
    image: victoriametrics/vmagent:latest
    container_name: mvno-vmagent
    volumes:
      - ./configs/victoria-metrics/scrape.yml:/etc/prometheus/prometheus.yml:z
    depends_on:
      - victoria-metrics
    networks:
      - mvno_net
    restart: "no"

  # 8. Visualization NOC
  grafana:
    image: grafana/grafana-oss:latest
    container_name: mvno-grafana
    ports:
      - "3000:3000"
    volumes:
      - ./state/grafana:/var/lib/grafana:z
    depends_on:
      - victoria-metrics
    networks:
      - mvno_net
    restart: "no"
```

---

## 4. Port Binding Summary

| Component | Target Port | Protocol | Usage | Podman Rootless Mode |
| :--- | :--- | :--- | :--- | :--- |
| **Kamailio** | `5060` | UDP / TCP | SIP Client Calling | Native bind (no changes) |
| **rtpengine** | `30000-30100` | UDP | Media Plane Streaming | Native bind (no changes) |
| **OsmoSMSC** | `2775` | TCP | SMPP SMS Delivery | Native bind (no changes) |
| **FastAPI** | `8080` | TCP | Interception REST API | Native bind (no changes) |
| **VictoriaMetrics**| `8428` | TCP | Metrics ingestion | Native bind (no changes) |
| **Grafana** | `3000` | TCP | NOC Admin dashboard | Native bind (no changes) |

---

## 5. MVNO Core Integration Flow & Steps

This section details the step-by-step runbook to integrate your MVNO core components with each other and connect them to the AI Filtration REST APIs.

### Step 1: Database Setup and SQLite Hardening
Initialize the database files and configure them for high concurrency (WAL Mode) before booting any core services:
1. **Initialize Kamailio DB**: Use `kamdbctl` to generate the SQLite database for subscriber location mapping:
   ```bash
   kamdbctl create
   ```
2. **Apply WAL PRAGMAs**: Run SQLite tuning on both the Kamailio registry DB and the Osmocom HLR DB:
   ```bash
   sqlite3 /home/zkhattab/MVNO/configs/kamailio/kamailio.db "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
   sqlite3 /home/zkhattab/MVNO/configs/osmocom/hlr.db "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
   ```

### Step 2: Establish the Media Plane Connection (Kamailio ↔ rtpengine)
Link the signaling server (Kamailio) with the packet forwarding proxy (rtpengine):
1. **Set rtpengine listening socket**: In `configs/rtpengine/rtpengine.conf`, configure the control interface:
   ```ini
   listen-ng = 127.0.0.1:22222
   ```
2. **Configure Kamailio module**: In `configs/kamailio/kamailio.cfg`, load the module and point it to the rtpengine socket:
   ```kamailio
   loadmodule "rtpengine.so"
   modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:22222")
   ```
3. **Trigger media redirection**: Within Kamailio's `route[LOCATION]` block, invoke rtpengine to manage the stream:
   ```kamailio
   route[LOCATION] {
       if (is_method("INVITE")) {
           rtpengine_manage("record-call=yes metadata=JSON");
       }
   }
   ```

### Step 3: Link Interception Webhooks (Core ↔ FastAPI Gateway)
Configure the signaling systems to call the API Gateway for approval before routing traffic:
1. **SMS Interception**: In `osmo-smsc.cfg`, route incoming messages to the ESME interface mapped to the FastAPI gateway:
   ```
   smpp
    esme mvno-api-route
     system-id mvno-api
     alert-notifications
   ```
2. **Call Interception**: In `kamailio.cfg`, load the `http_client` module and execute a `POST` query inside the INVITE route block:
   ```kamailio
   loadmodule "http_client.so"
   modparam("http_client", "httpcon", "api_gateway=>http://127.0.0.1:8080/api/v1/intercept")
   
   # Inside INVITE handler
   http_post("api_gateway", "/call", "$var(payload)", "$var(response)");
   ```

### Step 4: Configure the Speech Translation Pipeline (rtpengine ↔ Vosk ↔ AI Filter)
Set up the automated loop that records media, transcribes it, and routes it to the AI filter:
1. **Set shared spool**: Point rtpengine's recording path to the shared volume mount in `rtpengine.conf`:
   ```ini
   recording-dir = /var/spool/rtpengine
   recording-method = pcap
   recording-format = wav
   ```
2. **Launch Translation Worker**: Start `vosk_worker.py`. This daemon polls `/var/spool/rtpengine` using inotify:
   - When a `.wav` file is finalized, it loads the offline English model.
   - It transcribes the audio to text.
   - It performs a `POST` request containing the text transcript to the external AI Filtration REST API (`https://github.com/AI-SpamFilter-PMN/MVNO`).

### Step 5: Observability Aggregation (vmagent ↔ VictoriaMetrics)
Connect the lightweight time-series stack to scrape metrics:
1. **Define target profiles**: In `configs/victoria-metrics/scrape.yml`, configure scraping parameters for Kamailio and rtpengine:
   ```yaml
   scrape_configs:
     - job_name: 'kamailio'
       static_configs:
         - targets: ['127.0.0.1:5060']  # Kamailio metrics endpoint
     - job_name: 'rtpengine'
       static_configs:
         - targets: ['127.0.0.1:22222'] # rtpengine stats socket
   ```
2. **Set ingestion write-path**: Point `vmagent` to push all aggregated telemetry to the VictoriaMetrics TSDB single-binary database running on port `8428`.

