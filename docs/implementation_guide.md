# MVNO Interception & Monitoring Core — Complete Implementation Guide

A comprehensive guide to building a rootless containerized MVNO core network that intercepts SMS and voice traffic, performs offline speech-to-text transcription, and connects to an external AI spam filtration gateway.

---

## Table of Contents
1. [Critical Thinking & Problem-Solving](#1-critical-thinking--problem-solving-methodology)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites](#3-prerequisites)
4. [Project Scaffolding](#4-project-scaffolding)
5. [Docker Compose Orchestration](#5-docker-compose-orchestration)
   - [5A. docker-compose.yml](#5a-docker-composeyml)
   - [5B. Osmocom Dockerfile](#5b-osmocom-dockerfile)
6. [Core Network Configs](#6-core-network-configurations)
   - [6A. rtpengine.conf](#6a-rtpengine-configsrtpenginertpengineconf)
   - [6B. kamailio.cfg](#6b-kamailio-configskamailiokamailiocfg)
   - [6C. osmo-smsc.cfg](#6c-osmo-smsc-configsosmocomosmo-smsccfg)
   - [6D. scrape.yml](#6d-victoriametrics-scrape-configsvictoria-metricsscrapeyml)
7. [FastAPI Interception Gateway](#7-fastapi-interception-gateway)
8. [Data Pipeline](#8-data-pipeline)
   - [8A. Vosk Worker](#8a-vosk-worker)
   - [8B. Vector Log Shipper](#8b-vector-log-shipper)
9. [Makefile](#9-makefile)
10. [Building & Testing](#10-building--testing)
11. [Troubleshooting](#11-troubleshooting)
12. [Appendix](#12-appendix)

---

## 1. Critical Thinking & Problem-Solving Methodology

This section is the most important one in the guide. The config files and code will be obsolete in a year — but the way you *think* about complex systems will serve you for your entire career.

### The Core Telecom Mental Model: Trace the Data Flow

Before writing a single line of config or code, ask yourself:

> **"If I'm a packet/message entering this system, what happens to me step by step?"**

For this project, there are exactly two data flows. Internalize them:

**Flow A — SMS:**
```
SMPP Client → OsmoSMSC (port 2775) → FastAPI /intercept/sms → AI Filter → allow:true/false → deliver or drop
```

**Flow B — Voice Call:**
```
SIP Phone (port 5060) → Kamailio → FastAPI /intercept/call → AI Filter → allow → rtpengine (media proxy + WAV recording) → Vosk Worker (STT transcript) → FastAPI /transcript → AI Filter
```

Every single config line you write serves one of these two flows. If you can't explain which flow a line belongs to, you don't understand why you're writing it.

### The 5-Step Problem-Solving Loop

Apply this to every component you implement:

| Step | Question to Ask | Example (Kamailio) |
|------|----------------|-------------------|
| **1. Purpose** | What does this component do in one sentence? | "Kamailio is the SIP registrar — it authenticates users and routes calls." |
| **2. Input** | What data does it receive, from where, on what port/protocol? | "SIP INVITE on UDP 5060 from a phone." |
| **3. Output** | What data does it send, to where? | "RTP media to rtpengine, HTTP POST to FastAPI." |
| **4. Failure mode** | What happens if this component is down? | "No calls can be made. SMS still works (separate path)." |
| **5. Verify** | How do I know it's working? | "SIP registration shows in `kamctl`, logs show no errors." |

### Critical Thinking Techniques for Telecom Systems

#### 1. Think in Layers (OSI Model)

Every telecom system maps to OSI layers. When debugging, identify which layer is failing:

| OSI Layer | In This Project | Where to Debug |
|-----------|----------------|----------------|
| L7 Application | FastAPI, AI Filter | `/api/v1/intercept/sms` response, FastAPI logs |
| L6 Presentation | SIP/SDP bodies, SMPP PDUs | Kamailio xlog, tcpdump on port 5060/2775 |
| L5 Session | SIP dialog (INVITE→200→ACK→BYE) | Kamailio `tm` module, `ngrep` on SIP traffic |
| L4 Transport | TCP/UDP ports | `podman logs`, `ss -tlnp` |
| L3 Network | Container bridge `mvno_net` | `podman network inspect mvno_net` |
| L1-2 Cabling/Containers | Podman, host OS | `podman ps`, `make logs` |

**Rule of thumb:** 80% of bugs are at L4 (port not listening) or L7 (wrong API payload). Start there.

#### 2. Practice Failure Mode Analysis

Before every `make up`, predict what will fail. This trains your intuition:

```
"If MongoDB isn't ready when Kamailio starts → Kamailio might crash on DB init."
"If FastAPI times out → Kamailio's SLA fallback whitelists the call."
"If rtpengine isn't running → Kamailio can't anchor media, call fails."
```

Write these predictions down. After running, check which were right. Over time, you'll predict 90% of failures before they happen.

#### 3. The "Why Not?" Reframe

Whenever you see a technology choice in this guide, ask:

> **"Why not use X instead?"**

| Choice | Alternative | Answer in This Project |
|--------|------------|----------------------|
| SQLite | PostgreSQL | "Zero server process. 2MB RAM vs 100MB. WAL mode handles concurrent reads/writes at sandbox scale." |
| Vosk | Whisper AI | "40MB model vs 1.5GB. Runs on CPU without GPU. No cloud dependency." |
| Podman | Docker | "Rootless by default, daemonless, 0MB idle. Compose syntax is identical." |
| Vector | Filebeat | "Single Rust binary (5MB). No GC pauses. Built-in backpressure to disk." |

When you can answer "why not" for every choice, you've internalized the architecture.

#### 4. Incremental Verification (The Most Important Skill)

**Never run `make up` and hope everything works.** That's guessing, not engineering. Instead:

```
Step 1: Can I build each container image individually?
  → podman build -f telecom-api/Dockerfile -t mvno-api .
  → podman build -f configs/osmocom/Dockerfile -t mvno-osmo .

Step 2: Can each container start alone?
  → podman run --rm mvno-api curl localhost:8080/live
  → podman run --rm mvno-osmo osmo-msc --version

Step 3: Can two containers talk to each other?
  → Run them on the same podman network, test with a simple curl

Step 4: Can the full stack start?
  → make up
```

Each step takes 30 seconds. If something fails, you know *exactly* which step it broke — not "something in docker-compose failed."

#### 5. Log-Driven Debugging

Before running any component, know where its logs go:

| Component | Log Location | How to Read |
|-----------|-------------|-------------|
| Kamailio | `podman logs mvno-kamailio` or syslog | Search for "ERROR", "WARN", "BLOCKED" |
| OsmoSMSC | `podman logs mvno-osmosmsc` | Search for "SMPP", "delivery", "error" |
| rtpengine | `podman logs mvno-rtpengine` | Search for "media", "port", "error" |
| FastAPI | `podman logs mvno-api` | Search for "POST", "allow", "error" |
| Vosk | `podman logs mvno-vosk` | Search for "Processing", "Transcribed", "Failed" |
| Vector | `podman logs mvno-vmagent` | Search for "parse", "error" |
| VictoriaMetrics | `podman logs mvno-victoriametrics` | Search for "error" |

**Pro tip:** In a separate terminal, run `make logs` (which runs `podman-compose logs -f`) before issuing any test command. You see failures in real-time as they happen.

### How to Use This Guide for Maximum Learning

Don't copy-paste. Do this instead:

1. **Read a section** (e.g., §4B Docker Compose)
2. **Close the file** or cover the code block
3. **Write it from memory** — then check against the guide
4. **For every mistake** you make, ask "Why did I write that wrong?"
   - Was it a typo? (slow down)
   - Was it a misunderstanding of the config format? (read the docs)
   - Was it a conceptual gap? (re-read the architecture)

This is called **active recall** and it's the fastest way to build deep understanding. The mistakes you make while learning are *more valuable* than getting it right the first time.

---

Now proceed to the architecture overview, then apply these techniques to each section.

---

## 2. Architecture Overview

```
┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
│  SIP Phones  │────▶│   Kamailio   │────▶│   rtpengine      │
│  (UE/IMS)    │     │  (Registrar) │     │  (Media Proxy)   │
└──────────────┘     └──────┬───────┘     └────────┬─────────┘
                            │                      │
┌──────────────┐     ┌──────▼───────┐     ┌────────▼─────────┐
│  SMPP Client │────▶│  OsmoSMSC    │     │  /var/spool/rtp  │
│  (ESME)      │     │  (SMS-C)     │     │  *.wav + *.json  │
└──────────────┘     └──────┬───────┘     └────────┬─────────┘
                            │                      │
                     ┌──────▼──────────────────────▼─────────┐
                     │         FastAPI Gateway (:8080)        │
                     │  POST /api/v1/intercept/sms & /call    │
                     │  GET /live  /ready                     │
                     └──────┬──────────────────────┬──────────┘
                            │                      │
                     ┌──────▼──────┐      ┌────────▼─────────┐
                     │  AI Spam    │      │  vosk_worker.py   │
                     │  Filter API │      │  (STT Pipeline)   │
                     └─────────────┘      └──────────────────┘
```

### Four Layers

| Layer | Components | Purpose |
|-------|-----------|---------|
| Access | SIP/IMS Phones, SMPP Clients | UE connectivity |
| MVNO Core | Kamailio, rtpengine, OsmoSMSC | SIP routing, media anchoring, SMS store-and-forward |
| Integration | FastAPI, Vosk Worker, Vector | AI filter gateway, speech-to-text, log shipping |
| Observability | VictoriaMetrics, vmagent, Grafana | Metrics collection and dashboards |

### eTOM Alignment

**eTOM** (Enhanced Telecom Operations Map) is the TM Forum's industry-standard business process framework for telecom operators. This project maps to three eTOM domains:

| eTOM Domain | Our Implementation |
|-------------|-------------------|
| **Fulfilment** | SMS routing via OsmoSMSC, SIP call routing via Kamailio, media anchoring via rtpengine |
| **Assurance** | Real-time interception, AI spam classification, offline STT transcription, voice biometrics, DTMF logging, geofencing, EIR device binding |
| **Billing / OCS** | Prepaid balance check before allowing calls/SMS via FastAPI SQLite queries |

These are the three badges shown in the README header. Mapping to eTOM demonstrates alignment with real telecom industry standards, not just ad-hoc software engineering.

---

## 3. Prerequisites

### Required Tools

Choose your distro:

```bash
# ─── Debian / Ubuntu (apt) ──────────────────────────────
sudo apt update && sudo apt install -y podman podman-compose python3 python3-pip sqlite3
# (Optional) sipp: sudo apt install -y sipp

# ─── Arch / CachyOS (pacman) ────────────────────────────
sudo pacman -S --needed podman podman-compose python python-pip sqlite3
# (Optional) sipp — available in AUR: yay -S sipp

# ─── Fedora / RHEL (dnf / yum) ──────────────────────────
sudo dnf install -y podman podman-compose python3 python3-pip sqlite3
# (Optional) sipp: sudo dnf install -y sipp

# ─── Common (all distros) ────────────────────────────────
# Verify rootless mode
podman info | grep rootless
# Expected: rootless: true

# Enable user lingering (containers stay alive after logout)
sudo loginctl enable-linger $(whoami)
```

### Why These Choices

| Decision | Alternative | Why Chosen |
|----------|------------|------------|
| Podman over Docker | Docker | Rootless by default, no daemon = 0MB idle, Compose compatible |
| SQLite over PostgreSQL | Postgres | Zero server process, RAM cap ~2MB vs 100MB+. WAL mode handles concurrent reads/writes for sandbox scale |
| Vosk over Whisper | Whisper | 40MB offline model vs 1.5GB. Runs on any CPU without GPU. Zero cloud latency |
| FastAPI over Flask | Flask | Native async handles concurrent carrier requests. Auto-generated OpenAPI docs. Pydantic validation |
| Vector over Filebeat | Filebeat | Single Rust binary (5MB), zero GC pauses, built-in backpressure, VRL transform language |
| VictoriaMetrics over Prometheus | Prometheus | Single binary (20MB) vs 300MB. Same scraping protocol. Grafana compatible |

---

## 4. Project Scaffolding

```bash
cd /home/zkhattab/MVNO

# Create directory structure
mkdir -p configs/{kamailio,osmocom,rtpengine,victoria-metrics}
mkdir -p telecom-api telecom-data-pipeline
mkdir -p state/{spool,mongodb,vm-data,grafana,hlr}

# Verify structure
find . -type d | sort
```

### Complete File Tree

```
/home/zkhattab/MVNO/
├── .gitignore                    # Ignores *.db, .env, state/, __pycache__
├── README.md                     # Project overview
├── Makefile                      # Developer lifecycle commands
├── docker-compose.yml            # Rootless container stack
├── configs/
│   ├── kamailio/
│   │   └── kamailio.cfg          # SIP routing + security + rtpengine
│   ├── osmocom/
│   │   ├── osmo-smsc.cfg         # SMSC SMPP + rate limits
│   │   └── Dockerfile            # Osmocom image (debian + apt install)
│   ├── rtpengine/
│   │   └── rtpengine.conf        # Media ports + recording + DTMF
│   └── victoria-metrics/
│       └── scrape.yml            # vmagent scrape targets
├── telecom-api/
│   ├── main.py                   # FastAPI interception gateway
│   ├── requirements.txt          # fastapi, uvicorn, pydantic, httpx
│   └── Dockerfile                # Multi-stage python:3.11-alpine
├── telecom-data-pipeline/
│   ├── vosk_worker.py            # Offline STT + voice biometrics
│   ├── vector.toml               # Log parsing + forwarding
│   ├── requirements.txt          # vosk, soundfile, numpy, httpx
│   └── Dockerfile.vosk           # Multi-stage with build deps
├── state/                        # Runtime data (gitignored)
│   ├── spool/                    # rtpengine WAV recordings
│   ├── mongodb/                  # MongoDB WiredTiger storage
│   ├── vm-data/                  # VictoriaMetrics TSDB
│   ├── grafana/                  # Grafana dashboards
│   └── hlr/                      # OsmoHLR data
└── docs/
    ├── architecture_flow.svg      # Architecture diagram
    ├── deployment_guide.md        # Deployment runbook
    ├── implementation_plan.md     # Original planning doc
    ├── best_practices.md          # SOTA best practices
    └── implementation_guide.md    # This file — full implementation guide
```

---

## 5. Docker Compose Orchestration

**Why read this first?** Before writing any config file, you need to know:
- Container hostnames (`rtpengine`, `telecom-api`, `kamailio`) — these appear in every config
- Port mappings (`22222`, `8080`, `5060`) — used in module parameters
- Volume mount paths (`/etc/kamailio`, `/var/spool/rtpengine`) — where configs and data live
- Network topology — which containers can talk to each other

### 5A. `docker-compose.yml`

Rootless-compliant container stack. All services use `restart: "no"` for zero idle resource consumption. Ports above 1024. SELinux `:z` volume labels. Healthcheck-based dependency ordering.

Osmocom uses a custom build (see §4B) because no pre-built `osmo-msc-latest` image exists on any registry.

```yaml
version: "3.8"

networks:
  mvno_net:
    driver: bridge

services:
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
    healthcheck:
      test: mongosh --eval 'db.runCommand({ping:1})' --quiet
      interval: 10s
      timeout: 5s
      retries: 3

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

  kamailio:
    image: kamailio/kamailio:5.7-alpine
    container_name: mvno-kamailio
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
    volumes:
      - ./configs/kamailio:/etc/kamailio:z
      - ./state/kamailio.db:/etc/kamailio/kamailio.db:z
    depends_on:
      rtpengine:
        condition: service_started
    networks:
      - mvno_net
    restart: "no"

  osmo-smsc:
    build:
      context: ./configs/osmocom
    container_name: mvno-osmosmsc
    ports:
      - "2775:2775"
    volumes:
      - ./configs/osmocom:/etc/osmocom:z
      - ./state/hlr:/var/lib/osmocom:z
    networks:
      - mvno_net
    restart: "no"

  telecom-api:
    build:
      context: ./telecom-api
    container_name: mvno-api
    ports:
      - "8080:8080"
    volumes:
      - ./state/kamailio.db:/etc/kamailio/kamailio.db:z
    networks:
      - mvno_net
    restart: "no"

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

  vmagent:
    image: victoriametrics/vmagent:latest
    container_name: mvno-vmagent
    volumes:
      - ./configs/victoria-metrics/scrape.yml:/etc/prometheus/prometheus.yml:z
    depends_on:
      victoria-metrics:
        condition: service_started
    networks:
      - mvno_net
    restart: "no"

  grafana:
    image: grafana/grafana-oss:latest
    container_name: mvno-grafana
    ports:
      - "3000:3000"
    volumes:
      - ./state/grafana:/var/lib/grafana:z
    depends_on:
      victoria-metrics:
        condition: service_started
    networks:
      - mvno_net
    restart: "no"

  vosk-worker:
    build:
      context: ./telecom-data-pipeline
      dockerfile: Dockerfile.vosk
    container_name: mvno-vosk
    volumes:
      - ./state/spool:/var/spool/rtpengine:z
      - ./state/vosk-model:/opt:z
    depends_on:
      telecom-api:
        condition: service_started
    networks:
      - mvno_net
    restart: "no"
```

### Container Hostname Reference

When writing configs, use these container service names as DNS hostnames (Docker/Podman internal DNS resolves them automatically on the `mvno_net` bridge):

| Container | Hostname (internal) | Purpose |
|-----------|-------------------|---------|
| `mvno-rtpengine` | `rtpengine` | Kamailio's rtpengine module connects here port 22222 |
| `mvno-kamailio` | `kamailio` | SIP signaling, port 5060 |
| `mvno-osmosmsc` | `osmo-smsc` | SMPP on port 2775 |
| `mvno-api` | `telecom-api` | FastAPI on port 8080 — Kamailio/Vector POST here |
| `mvno-victoriametrics` | `victoria-metrics` | TSDB on port 8428 |
| `mvno-vmagent` | `vmagent` | Scrapes metrics from other containers |
| `mvno-grafana` | `grafana` | Dashboard on port 3000 |
| `mvno-vosk` | `vosk-worker` | STT pipeline — no exposed ports |
| `mvno-mongodb` | `mongodb` | Metadata store on port 27017 |

### 5B. Osmocom Dockerfile

**Why is this needed?** There is no pre-built `osmocom/osmo-msc-latest` image on Docker Hub or any other registry. The official Osmocom [docker-playground](https://github.com/osmocom/docker-playground) builds from source and is designed for CI/testing, not lightweight deployment. Instead, we build our own image using Debian's official `osmo-msc` and `osmo-hlr` packages — this is faster, smaller, and simpler.

#### `configs/osmocom/Dockerfile`

```dockerfile
# Builds a lightweight Osmocom image with osmo-msc + osmo-hlr
# from Debian Bookworm's binary packages (no source compilation).

FROM debian:bookworm-slim

# Osmocom package archive signing key
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Add Osmocom's latest stable repository for Debian Bookworm
RUN wget -q -O /usr/share/keyrings/osmocom.asc \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12/Release.key \
    && echo "deb [signed-by=/usr/share/keyrings/osmocom.asc] \
    https://downloads.osmocom.org/packages/osmocom:/latest/Debian_12 ./" \
    > /etc/apt/sources.list.d/osmocom.list

# Install osmo-msc (includes SMSC/SMPP) and osmo-hlr
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    osmo-msc \
    osmo-hlr \
    osmocom-sccp \
    && rm -rf /var/lib/apt/lists/*

# Config directory (mounted as volume from host)
VOLUME ["/etc/osmocom", "/var/lib/osmocom"]

# Default config path (override via -c flag)
ENV OSMO_MSC_CONFIG=/etc/osmocom/osmo-smsc.cfg

EXPOSE 2775

CMD ["osmo-msc", "-c", "/etc/osmocom/osmo-smsc.cfg"]
```

---

## 6. Core Network Configurations

Now that you know the container hostnames and port mappings from §4, you can write the config files that reference them.

### 6A. rtpengine — `configs/rtpengine/rtpengine.conf`

**Why rtpengine over rtpproxy?** rtpengine runs its forwarding plane in the Linux kernel via a DKMS module. During active calls, RTP packets bypass userspace entirely — near-zero CPU usage. It also natively supports call recording, DTMF logging, and SRTP-to-cleartext transcoding.

```ini
listen-ng = 0.0.0.0:22222

port-min = 30000
port-max = 30100

recording-dir = /var/spool/rtpengine
recording-method = pcap
recording-format = wav

dtmf-log = yes

transcription-dir = /var/spool/rtpengine
transcription-format = json

media-timeout = 1800
max-sessions = 1000
log-level = 3
```

### 6B. Kamailio — `configs/kamailio/kamailio.cfg`

**Why Kamailio?** It's the most performant open-source SIP server. Handles registration, authentication, routing, and hooks rtpengine for media anchoring. We load modules only when needed to keep RAM low (~15MB idle). Implements PIKE rate limiting, STIR/SHAKEN anti-spoofing, and SLA fallback via HTable.

Note the hostnames: `rtpengine:22222` and `telecom-api:8080` — these are the container names defined in `docker-compose.yml` (see §4A).

```c
// ==========================================================
// MVNO Interception Core — Kamailio SIP Routing
// ==========================================================

debug=3
log_stderror=no
memlog=5
cfgpkglog=5

mpath="/usr/lib/x86_64-linux-gnu/kamailio/modules/"

// ─── Core Modules ──────────────────────────────────────
loadmodule "sl.so"
loadmodule "tm.so"
loadmodule "rr.so"
loadmodule "maxfwd.so"
loadmodule "textops.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "mi_fifo.so"

// ─── Database (SQLite WAL for subscriber registry) ─────
loadmodule "db_sqlite.so"
loadmodule "usrloc.so"
modparam("usrloc", "db_url", "sqlite:///etc/kamailio/kamailio.db")
modparam("usrloc", "db_mode", 2)

// ─── Authentication ─────────────────────────────────────
loadmodule "auth.so"
loadmodule "auth_db.so"
modparam("auth_db", "db_url", "sqlite:///etc/kamailio/kamailio.db")
modparam("auth_db", "calculate_ha1", 1)
modparam("auth_db", "password_column", "password")

// ─── Media Plane (rtpengine) ────────────────────────────
// Hostname "rtpengine" = container name from docker-compose.yml
loadmodule "rtpengine.so"
modparam("rtpengine", "rtpengine_sock", "udp:rtpengine:22222")

// ─── HTTP Client (FastAPI integration) ──────────────────
// Hostname "telecom-api" = container name from docker-compose.yml
loadmodule "http_client.so"
modparam("http_client", "httpcon", "api_gw=>http://telecom-api:8080/api/v1")

// ─── Security: PIKE Rate Limiting ───────────────────────
loadmodule "pike.so"
modparam("pike", "sampling_time_unit", 5)
modparam("pike", "reqs_density_per_unit", 30)

// ─── Security: HTable for IP bans + SLA cache ──────────
loadmodule "htable.so"
modparam("htable", "htable", "ban=>size=8;autoexpire=300;")
modparam("htable", "htable", "whitelist=>size=8;autoexpire=3600;")
modparam("htable", "htable", "blacklist=>size=8;autoexpire=3600;")

// ─── Topology Hiding ────────────────────────────────────
loadmodule "topoh.so"
modparam("topoh", "mask_key", "MVNOSECRETKEY")
modparam("topoh", "mask_ip", "10.0.0.1")

// ─── Main Request Route ─────────────────────────────────
request_route {
    // Layer 1: PIKE — block IPs exceeding rate limit
    if ($sht(ban=>$si) == 1) {
        xlog("L_WARN", "BLOCKED banned IP: $si\n");
        send_reply(403, "Forbidden");
        exit;
    }
    if (!pike_check_req()) {
        xlog("L_WARN", "PIKE: rate limit exceeded for $si\n");
        $sht(ban=>$si) = 1;
        send_reply(429, "Too Many Requests");
        exit;
    }

    // Layer 2: SLA Fallback HTable (Feature #7)
    if ($sht(whitelist=>$fU) == 1) {
        xlog("L_INFO", "SLA FALLBACK: $fU whitelisted\n");
        route(FORWARD);
        exit;
    }
    if ($sht(blacklist=>$fU) == 1) {
        xlog("L_WARN", "SLA FALLBACK: $fU blacklisted\n");
        send_reply(403, "Blacklisted");
        exit;
    }

    // Layer 3: STIR/SHAKEN Anti-Spoofing (Feature #2)
    if (is_method("INVITE") || is_method("REGISTER")) {
        if ($fU != $au && $au != "") {
            xlog("L_WARN", "STIR/SHAKEN: SPOOF $fU != $au\n");
            send_reply(407, "Proxy Authentication Required");
            exit;
        }
    }

    // Handle REGISTER
    if (is_method("REGISTER")) {
        if (!auth_check("$fd", "subscriber", "1")) {
            auth_challenge("$fd", "0");
            exit;
        }
        if (!save("location")) {
            sl_reply_error();
        }
        exit;
    }

    // Handle INVITE — check with FastAPI before routing
    if (is_method("INVITE")) {
        $var(payload) = "{"
            + "\"caller\":\"" + $fU + "\","
            + "\"callee\":\"" + $rU + "\","
            + "\"call_id\":\"" + $ci + "\""
            + "}";
        http_connect("api_gw", "/intercept/call", "", $var(payload));
        route(LOCATION);
    }

    route(FORWARD);
}

// Media anchor subroute
route[LOCATION] {
    if (is_method("INVITE")) {
        rtpengine_manage("record-call=yes metadata=JSON");
    }
    if (!lookup("location")) {
        send_reply(404, "Not Found");
        exit;
    }
    t_relay();
}

// Forward subroute
route[FORWARD] {
    if (!lookup("location")) {
        send_reply(404, "Not Found");
        exit;
    }
    t_relay();
}
```

### 6C. OsmoSMSC — `configs/osmocom/osmo-smsc.cfg`

The SMS center. Routes messages through the FastAPI gateway for AI classification before delivery. Note: the ESME route `mvno-api-route` points to the FastAPI container.

```
line-vty
 no login

smpp
 local-tcp-ip 0.0.0.0 2775
 system-id MVNO_SMSC
 max-pending-requests 100

 esme mvno-api-route
  system-id mvno-api
  password changeme
  interface-version 34
  alert-notifications
 !

 delivery-report-format plain

hlr
 db /etc/osmocom/hlr.db
 db-wal yes
 db-sync normal

subscriber create imsi 001010000000001 msisdn 15551234567
subscriber create imsi 001010000000002 msisdn 15557654321
```

### 6D. VictoriaMetrics Scrape — `configs/victoria-metrics/scrape.yml`

vmagent scrape targets for metrics collection. Note the hostnames match container names from docker-compose.yml.

```yaml
scrape_configs:
  - job_name: 'kamailio'
    static_configs:
      - targets: ['kamailio:8080']

  - job_name: 'rtpengine'
    static_configs:
      - targets: ['rtpengine:9900']

  - job_name: 'telecom-api'
    static_configs:
      - targets: ['telecom-api:8080']

  - job_name: 'vmagent'
    static_configs:
      - targets: ['localhost:8429']
```

---

## 7. FastAPI Interception Gateway

### `telecom-api/main.py`

The policy decision point. Every SMS and call passes through this API for allow/block decisions. Implements OCS balance check (Feature #1) and EIR device binding (Feature #4).

```python
"""
MVNO Interception Gateway — FastAPI Async Application

Endpoints:
  GET  /live                          — Liveness probe
  GET  /ready                         — Readiness (checks deps)
  POST /api/v1/intercept/sms          — SMS decision
  POST /api/v1/intercept/call         — Call decision
"""

import json
import sqlite3
import time
from contextlib import asynccontextmanager
from typing import Dict, Optional

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ─── Configuration ──────────────────────────────────────
SQLITE_DB = "/etc/kamailio/kamailio.db"
AI_FILTER_URL = "http://ai-filter:8000/api/v1/classify"
HTTP_TIMEOUT = 2.0

# In-memory EIR tracker (Feature #4)
# Structure: { imei: { "msisdn": str, "last_seen": float, "swap_count": int } }
eir_tracker: Dict[str, dict] = {}

# ─── Pydantic Models ────────────────────────────────────

class SMSInterceptRequest(BaseModel):
    sender: str = Field(..., description="Sender MSISDN")
    recipient: str = Field(..., description="Recipient MSISDN")
    content: str = Field(..., description="SMS message body")
    lac: Optional[str] = Field(None, description="Location Area Code")
    cell_id: Optional[str] = Field(None, description="Cell ID for geofencing")

class CallInterceptRequest(BaseModel):
    caller: str = Field(..., description="Caller MSISDN")
    callee: str = Field(..., description="Callee MSISDN")
    call_id: str = Field(..., description="SIP Call-ID")
    imei: Optional[str] = Field(None, description="Device IMEI")

class InterceptResponse(BaseModel):
    allow: bool = Field(..., description="Whether to allow the SMS/call")
    reason: str = Field("", description="Decision explanation")

# ─── Application ────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield

app = FastAPI(title="MVNO Interception Gateway", version="1.0.0", lifespan=lifespan)

# ─── Feature: Prepaid OCS Interception (Feature #1) ─────
def get_subscriber_balance(msisdn: str) -> int:
    """
    Query Kamailio SQLite subscriber table for balance.
    Returns 0 for unknown/depleted subscribers — blocks the session.
    """
    try:
        conn = sqlite3.connect(SQLITE_DB)
        cursor = conn.execute(
            "SELECT balance FROM subscriber WHERE msisdn = ?", (msisdn,)
        )
        row = cursor.fetchone()
        conn.close()
        if row and row[0] is not None:
            return row[0]
        return 0
    except Exception:
        return -1  # DB error = fail open for sandbox

# ─── Feature: EIR Device Binding (Feature #4) ────────────
def check_eir_binding(imei: str, msisdn: str) -> bool:
    """
    Track IMEI-IMSI pairs. If an IMEI swaps between MSISDNs >3 times
    in 10 minutes, flag as spam box (hardware used to spam from multiple numbers).
    """
    now = time.time()
    if imei in eir_tracker:
        entry = eir_tracker[imei]
        if entry["msisdn"] != msisdn:
            entry["swap_count"] += 1
            entry["last_seen"] = now
            if entry["swap_count"] > 3:
                return False
        else:
            entry["last_seen"] = now
    else:
        eir_tracker[imei] = {"msisdn": msisdn, "last_seen": now, "swap_count": 0}
    return True

# ─── Health Endpoints ────────────────────────────────────

@app.get("/live")
async def liveness():
    return {"status": "alive"}

@app.get("/ready")
async def readiness():
    checks = {"sqlite": False, "ai_filter": False}
    try:
        conn = sqlite3.connect(SQLITE_DB)
        conn.execute("SELECT 1")
        conn.close()
        checks["sqlite"] = True
    except Exception:
        checks["sqlite"] = False
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            resp = await client.get(f"{AI_FILTER_URL}/health")
            checks["ai_filter"] = resp.status_code == 200
    except Exception:
        checks["ai_filter"] = False
    healthy = all(checks.values())
    return JSONResponse(
        {"status": "ready" if healthy else "degraded", "checks": checks},
        status_code=200 if healthy else 503,
    )

# ─── Interception Endpoints ─────────────────────────────

@app.post("/api/v1/intercept/sms", response_model=InterceptResponse)
async def intercept_sms(req: SMSInterceptRequest):
    """SMS interception: OCS check + AI classification."""
    balance = get_subscriber_balance(req.sender)
    if balance == 0:
        return InterceptResponse(allow=False, reason="Prepaid balance exhausted")

    payload = {
        "type": "sms",
        "sender": req.sender,
        "recipient": req.recipient,
        "content": req.content,
        "lac": req.lac,
        "cell_id": req.cell_id,
    }
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            resp = await client.post(f"{AI_FILTER_URL}/sms", json=payload)
            result = resp.json()
            return InterceptResponse(
                allow=result.get("allow", True), reason=result.get("reason", "")
            )
    except httpx.TimeoutException:
        return InterceptResponse(allow=True, reason="AI filter unreachable — SLA allow")

@app.post("/api/v1/intercept/call", response_model=InterceptResponse)
async def intercept_call(req: CallInterceptRequest):
    """Call interception: OCS + EIR check + AI classification."""
    balance = get_subscriber_balance(req.caller)
    if balance == 0:
        return InterceptResponse(allow=False, reason="Prepaid balance exhausted")

    if req.imei:
        if not check_eir_binding(req.imei, req.caller):
            return InterceptResponse(allow=False, reason="EIR: SIM swap detected")

    payload = {
        "type": "call",
        "caller": req.caller,
        "callee": req.callee,
        "call_id": req.call_id,
    }
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            resp = await client.post(f"{AI_FILTER_URL}/call", json=payload)
            result = resp.json()
            return InterceptResponse(
                allow=result.get("allow", True), reason=result.get("reason", "")
            )
    except httpx.TimeoutException:
        return InterceptResponse(allow=True, reason="AI filter unreachable — SLA allow")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
```

### `telecom-api/requirements.txt`

```
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
pydantic>=2.0.0
httpx>=0.27.0
aiosqlite>=0.20.0
```

### `telecom-api/Dockerfile`

```dockerfile
FROM python:3.11-alpine AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-alpine
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY main.py .
RUN adduser -D mvno
USER mvno
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

---

## 8. Data Pipeline

### 8A. Vosk Worker

#### `telecom-data-pipeline/vosk_worker.py`

Monitors rtpengine's WAV spool, transcribes with Vosk, extracts voice biometrics (Feature #6: silence ratio, spectral flatness), parses DTMF from companion JSON (Feature #5), and posts to FastAPI.

```python
#!/usr/bin/env python3
"""
MVNO Speech-to-Text Pipeline — Vosk Worker

Features:
- Offline STT via Vosk (zero cloud latency)
- DTMF parsing from rtpengine JSON metadata (Feature #5)
- Voice biometrics: silence ratio + synthetic audio detection (Feature #6)
"""

import json
import logging
import os
import time
from pathlib import Path

import httpx
import soundfile as sf
import numpy as np
from vosk import Model, KaldiRecognizer

SPOOL_DIR = "/var/spool/rtpengine"
MODEL_PATH = "/opt/vosk-model-small-en-us-0.15"
MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
API_URL = "http://telecom-api:8080/api/v1/intercept/call"
POLL_INTERVAL = 2

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("vosk-worker")

def ensure_model():
    if not os.path.exists(MODEL_PATH):
        logger.info(f"Downloading Vosk model from {MODEL_URL}...")
        import urllib.request, zipfile
        zip_path = "/tmp/vosk-model.zip"
        urllib.request.urlretrieve(MODEL_URL, zip_path)
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall("/opt/")
        os.remove(zip_path)
        logger.info("Model downloaded")

def extract_voice_biometrics(wav_path: str) -> dict:
    """
    Feature #6: Analyze WAV for spam indicators.
    - Silence ratio: robocalls have high silence ratio
    - Spectral flatness: TTS audio has lower flatness than human speech
    """
    try:
        audio, sr = sf.read(wav_path)
        if len(audio.shape) > 1:
            audio = audio.mean(axis=1)
        audio = audio / (np.max(np.abs(audio)) + 1e-10)

        frame_length = int(sr * 0.02)
        energy = np.array([
            np.sum(audio[i:i+frame_length]**2)
            for i in range(0, len(audio) - frame_length, frame_length)
        ])
        silence_threshold = 0.01 * np.max(energy)
        silence_ratio = np.sum(energy < silence_threshold) / len(energy)

        spectrum = np.abs(np.fft.rfft(audio))
        spectral_flatness = np.exp(np.mean(np.log(spectrum + 1e-10))) / (np.mean(spectrum) + 1e-10)

        return {
            "silence_ratio": float(round(silence_ratio, 4)),
            "spectral_flatness": float(round(spectral_flatness, 4)),
            "duration_seconds": float(round(len(audio) / sr, 2)),
        }
    except Exception as e:
        logger.error(f"Biometrics error: {e}")
        return {"silence_ratio": 0.0, "spectral_flatness": 0.0, "duration_seconds": 0.0}

def parse_dtmf_metadata(json_path: str) -> list:
    """Feature #5: Extract DTMF tones from rtpengine companion JSON."""
    try:
        with open(json_path) as f:
            metadata = json.load(f)
        return metadata.get("dtmf_events", [])
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return []

def process_wav(wav_path: str):
    logger.info(f"Processing {wav_path}")
    try:
        wf = sf.SoundFile(wav_path, mode="r")
        rec = KaldiRecognizer(model, wf.samplerate)
        rec.SetWords(True)
        text_parts = []
        while True:
            data = wf.read(4000, dtype="int16")
            if len(data) == 0:
                break
            if rec.AcceptWaveform(data.tobytes()):
                result = json.loads(rec.Result())
                text_parts.append(result.get("text", ""))
        final_result = json.loads(rec.FinalResult())
        text_parts.append(final_result.get("text", ""))
        transcript = " ".join(filter(None, text_parts))

        biometrics = extract_voice_biometrics(wav_path)
        json_path = wav_path.replace(".wav", ".json")
        dtmf_events = parse_dtmf_metadata(json_path)

        call_metadata = {
            "audio_file": os.path.basename(wav_path),
            "transcript": transcript,
            "biometrics": biometrics,
            "dtmf_events": dtmf_events,
        }

        with httpx.Client(timeout=5.0) as client:
            resp = client.post(f"{API_URL}/transcript", json=call_metadata)
            resp.raise_for_status()

        logger.info(f"Transcribed: {transcript[:50]}...")
        os.remove(wav_path)
        if os.path.exists(json_path):
            os.remove(json_path)
    except Exception as e:
        logger.error(f"Failed: {e}")

if __name__ == "__main__":
    logger.info("Starting Vosk worker...")
    ensure_model()
    logger.info("Loading model...")
    model = Model(MODEL_PATH)
    logger.info("Model loaded. Watching spool...")
    while True:
        for wav_path in list(Path(SPOOL_DIR).glob("*.wav")):
            if time.time() - os.path.getmtime(wav_path) > 2:
                process_wav(str(wav_path))
        time.sleep(POLL_INTERVAL)
```

#### `telecom-data-pipeline/requirements.txt`

```
vosk>=0.3.45
soundfile>=0.12.1
numpy>=1.26.0
httpx>=0.27.0
```

#### `telecom-data-pipeline/Dockerfile.vosk`

```dockerfile
FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY vosk_worker.py .
RUN apt-get update && apt-get install -y --no-install-recommends libsndfile1 \
    && rm -rf /var/lib/apt/lists/*
RUN adduser -D mvno
USER mvno
CMD ["python", "vosk_worker.py"]
```

### 8B. Vector Log Shipper

#### `telecom-data-pipeline/vector.toml`

Tails Kamailio and OsmoSMSC logs. Parses SIP events, LAC/CellID (Feature #3), and IMEI-IMSI bindings (Feature #4). Forwards structured events to FastAPI.

```toml
data_dir = "/var/lib/vector"

[sources.kamailio_logs]
  type = "file"
  include = ["/var/log/kamailio/kamailio.log"]
  start_at_beginning = false

[sources.osmosmsc_logs]
  type = "file"
  include = ["/var/log/osmocom/osmo-smsc.log"]
  start_at_beginning = false

[transforms.parse_sip_events]
  type = "remap"
  inputs = ["kamailio_logs"]
  source = '''
    if (includes!(.message, "REGISTER")) {
      .event_type = "sip.register"
      .caller = parse_regex!(.message, r'From: <sip:(?P<caller>[^@]+)').caller
      .ip = parse_regex!(.message, r'\((UDP|TCP)\):(?P<ip>[0-9.]+)').ip
    } else if (includes!(.message, "INVITE")) {
      .event_type = "sip.invite"
      .caller = parse_regex!(.message, r'From: <sip:(?P<caller>[^@]+)').caller
      .callee = parse_regex!(.message, r'To: <sip:(?P<callee>[^@]+)').callee
    }
  '''

[transforms.parse_cellid]
  type = "remap"
  inputs = ["osmosmsc_logs"]
  source = '''
    if (includes!(.message, "delivery")) {
      .event_type = "sms.delivery_report"
      .lac = parse_regex!(.message, r'LAC=(?P<lac>[0-9A-F]+)').lac
      .cell_id = parse_regex!(.message, r'CellID=(?P<cell_id>[0-9A-F]+)').cell_id
      .msisdn = parse_regex!(.message, r'MSISDN=(?P<msisdn>\d+)').msisdn
    }
  '''

[transforms.imei_extraction]
  type = "remap"
  inputs = ["osmosmsc_logs"]
  source = '''
    if (includes!(.message, "IMSI") && includes!(.message, "IMEI")) {
      .event_type = "eir.binding"
      .imsi = parse_regex!(.message, r'IMSI=(?P<imsi>\d{15})').imsi
      .imei = parse_regex!(.message, r'IMEI=(?P<imei>\d{15})').imei
    }
  '''

[sinks.fastapi_events]
  type = "http"
  inputs = ["parse_sip_events", "parse_cellid", "imei_extraction"]
  uri = "http://telecom-api:8080/api/v1/events"
  method = "post"
  encoding.codec = "json"
  [sinks.fastapi_events.buffer]
    type = "disk"
    max_size = 104_857_600
    when_full = "block"
```

---

## 9. Makefile

### `Makefile`

```makefile
.PHONY: init up down ps logs test-sms test-call test-api clean rebuild

init-db:
	@echo "Initializing Kamailio subscriber database with WAL mode..."
	@mkdir -p state
	@sqlite3 state/kamailio.db \
		"PRAGMA journal_mode=WAL;" \
		"PRAGMA synchronous=NORMAL;" \
		"PRAGMA busy_timeout=5000;" \
		"PRAGMA cache_size=-2000;" \
		"PRAGMA temp_store=MEMORY;" \
		"CREATE TABLE IF NOT EXISTS subscriber (" \
		"  id INTEGER PRIMARY KEY," \
		"  username VARCHAR(64) NOT NULL," \
		"  domain VARCHAR(64)," \
		"  password VARCHAR(64) NOT NULL," \
		"  ha1 VARCHAR(128)," \
		"  ha1b VARCHAR(128)," \
		"  msisdn VARCHAR(20) UNIQUE," \
		"  balance INTEGER DEFAULT 100," \
		"  imei VARCHAR(15)" \
		");" \
		"CREATE INDEX IF NOT EXISTS idx_msisdn ON subscriber(msisdn);"
	@sqlite3 state/kamailio.db \
		"INSERT OR IGNORE INTO subscriber (username, domain, password, msisdn, balance) " \
		"VALUES ('15551234567', 'mvno.local', 'testpass', '15551234567', 100);" \
		"INSERT OR IGNORE INTO subscriber (username, domain, password, msisdn, balance) " \
		"VALUES ('15557654321', 'mvno.local', 'testpass', '15557654321', 0);"
	@sqlite3 state/hlr.db \
		"PRAGMA journal_mode=WAL;" \
		"PRAGMA synchronous=NORMAL;"
	@echo "Databases initialized with WAL mode."

up:
	podman-compose up -d --build

down:
	podman-compose down

ps:
	podman ps

logs:
	podman-compose logs -f

test-sms:
	@echo "Sending test SMS via SMPP..."
	@python3 -c "
import smpplib.client, smpplib.constants
client = smpplib.client.Client('localhost', 2775)
client.connect()
client.bind_transmitter(system_id='mvno-api', password='changeme')
pdu = client.send_message(
    source_addr_ton=smpplib.constants.SMPP_TON_INTL,
    source_addr='15551234567',
    dest_addr_ton=smpplib.constants.SMPP_TON_INTL,
    destination_addr='15557654321',
    short_message=b'Hello from MVNO test!',
)
client.unbind()
client.disconnect()
print('SMS sent — check FastAPI logs for intercept decision')
	"

test-call:
	@echo "Simulating SIP call..."
	@sipp 127.0.0.1:5060 -s 15557654321 -l 1 -m 1 -aa -sf /dev/stdin << 'SIPP_XML'
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE scenario SYSTEM "sipp.dtd">
<scenario name="MVNO Call Test">
  <send retrans="500">
    <![CDATA[
      INVITE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port]
      From: "Test" <sip:15551234567@[remote_ip]>
      To: <sip:[service]@[remote_ip]>
      Call-ID: [call_id]
      CSeq: 1 INVITE
      Contact: <sip:15551234567@[local_ip]:[local_port]>
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>
  <recv response="100" optional="true"/>
  <recv response="180" optional="true"/>
  <recv response="200" rtd="true"/>
  <send>
    <![CDATA[
      ACK sip:[service]@[remote_ip] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port]
      From: "Test" <sip:15551234567@[remote_ip]>
      To: <sip:[service]@[remote_ip]>
      Call-ID: [call_id]
      CSeq: 1 ACK
      Contact: <sip:15551234567@[local_ip]:[local_port]>
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>
  <pause milliseconds="3000"/>
  <send retrans="500">
    <![CDATA[
      BYE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port]
      From: "Test" <sip:15551234567@[remote_ip]>
      To: <sip:[service]@[remote_ip]>
      Call-ID: [call_id]
      CSeq: 2 BYE
      Contact: <sip:15551234567@[local_ip]:[local_port]>
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>
  <recv response="200" rtd="true"/>
</scenario>
SIPP_XML

test-api:
	@echo "Checking FastAPI health..."
	@curl -s http://localhost:8080/live
	@echo ""
	@curl -s http://localhost:8080/ready
	@echo ""

clean:
	@echo "Removing all state data..."
	@rm -rf state/*
	@echo "Done."

rebuild: clean init-db up
	@echo "System rebuilt and ready."
```

---

## 10. Building & Testing

### Step-by-Step

```bash
# 1. Initialize databases
make init-db

# 2. Start the stack (builds all images including Osmocom)
make up

# 3. Verify containers
make ps

# 4. Watch logs
make logs

# 5. Test FastAPI health
make test-api
# Expected: {"status":"alive"} and {"status":"ready"}

# 6. Test SMS interception
make test-sms

# 7. Test call interception
make test-call

# 8. Open Grafana
echo "http://localhost:3000 (admin/admin)"

# 9. Open FastAPI docs
echo "http://localhost:8080/docs"

# 10. Open VictoriaMetrics
echo "http://localhost:8428/select/0/vmui/"
```

### Testing Zero-Balance Blocking

```bash
python3 -c "
import smpplib.client, smpplib.constants
client = smpplib.client.Client('localhost', 2775)
client.connect()
client.bind_transmitter(system_id='mvno-api', password='changeme')
client.send_message(
    source_addr_ton=smpplib.constants.SMPP_TON_INTL,
    source_addr='15557654321',  # balance=0 subscriber
    dest_addr_ton=smpplib.constants.SMPP_TON_INTL,
    destination_addr='15551234567',
    short_message=b'This should be blocked',
)
client.unbind()
client.disconnect()
print('Sent — expect allow:false in FastAPI logs')
"
```

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Containers exit immediately | Port conflict | `sudo lsof -i :5060` or `:8080`. Kill conflicting process. |
| Osmocom build fails | Missing `Dockerfile` in osmocom dir | Check `configs/osmocom/Dockerfile` exists (see §4B). |
| Kamailio won't start | Missing SQLite DB | Run `make init-db` before `make up`. |
| SMS not routing | Wrong SMPP password | Check `osmo-smsc.cfg` password matches client credentials. |
| No WAV in spool | rtpengine socket config wrong | Check Kamailio → rtpengine `rtpengine_sock` parameter. |
| Vosk idle (no transcription) | Model not yet downloaded | First run downloads ~40MB model via HTTP. Wait 30-60s. |
| SELinux volume errors | Missing `:z` flag | Add `:z` to volume definition in docker-compose.yml. |
| `podman-compose` not found | Not installed | Debian: `sudo apt install` · Arch: `sudo pacman -S` · Fedora: `sudo dnf install` · Or: `pip install podman-compose` |
| MongoDB connection refused | Container still starting | Wait 10-15s for first boot. Check `podman logs mvno-mongodb`. |
| Vector not parsing logs | Wrong log path | Verify Kamailio/OsmoSMSC write logs to paths in vector.toml. |
| FastAPI returns `allow:true` for everything | AI filter unreachable | Expected in sandbox — SLA fallback allows when filter is down. |

---

## 12. Appendix

### A. eTOM Reference

**eTOM (Enhanced Telecom Operations Map)** is the TM Forum's standard business process framework for telecom service providers. The three domains relevant to this project:

| eTOM Domain | TM Forum Definition | Our Implementation |
|-------------|-------------------|-------------------|
| **Fulfilment** | Order-to-service delivery, provisioning, activation | SIP call routing (Kamailio), SMS store-and-forward (OsmoSMSC), media anchoring (rtpengine) |
| **Assurance** | Real-time monitoring, QoS, fault management, fraud detection | Real-time interception, AI classification, Vosk STT transcription, voice biometrics, DTMF logging, LAC/CellID geofencing, EIR device binding, PIKE rate limiting, STIR/SHAKEN anti-spoofing |
| **Billing / OCS** | Usage metering, balance management, online charging | Prepaid balance check (FastAPI SQLite query) before allowing calls/SMS. Zero-balance = session dropped |

### B. Feature Integration Map

| # | Feature | Location | Mechanism |
|---|---------|----------|-----------|
| 1 | **Prepaid OCS Interception** | `telecom-api/main.py` + Kamailio HTTP call | Kamailio calls `POST /api/v1/intercept/call` or `/sms`. FastAPI queries subscriber SQLite balance. If 0 → `allow: false`. |
| 2 | **STIR/SHAKEN Anti-Spoofing** | `kamailio.cfg` request_route | Compares SIP `From` header (`$fU`) to authenticated username (`$au`). Mismatch → `407 Proxy Auth Required`. |
| 3 | **LAC/CellID Geofencing** | `vector.toml` → FastAPI → AI Filter | Vector parses Cell ID from OsmoSMSC delivery report logs. Forwards to FastAPI `/api/v1/events`. AI filter applies zone policies. |
| 4 | **EIR Device Binding** | `telecom-api/main.py:check_eir_binding()` | In-memory tracker maps IMEI→MSISDN. >3 swaps in 10min = spam box → `allow: false`. |
| 5 | **DTMF Interception** | `rtpengine.conf` + `vosk_worker.py` | rtpengine logs DTMF tones to companion JSON. Vosk worker parses and includes in API POST. |
| 6 | **Voice Biometrics** | `vosk_worker.py:extract_voice_biometrics()` | numpy FFT analysis. High silence ratio = robocall. Low spectral flatness = TTS synthesis. |
| 7 | **SLA Fallback HTable** | `kamailio.cfg` htable + http_client 1s timeout | If FastAPI times out, Kamailio checks local HTable whitelist/blacklist before routing. |

### C. Architectural Decisions Summary

| Decision | Alternative | Why Chosen |
|----------|------------|------------|
| **Kamailio** over OpenSIPS | OpenSIPS (simpler config) | Better rtpengine/pike/htable module support — critical for security features |
| **rtpengine** over rtpproxy | rtpproxy (lighter) | In-kernel forwarding + native recording + DTMF logging. Near-zero CPU. |
| **OsmoSMSC** over Kannel | Kannel (more popular) | Supports SS7 integration (future-proof), native SQLite WAL mode, cleaner SMPP |
| **FastAPI** over Flask/Express | Flask (simpler) | Async + Pydantic + auto-docs essential for a gateway handling concurrent carrier traffic |
| **Vosk** over Whisper | Whisper (more accurate) | 40MB offline model vs 1.5GB. Runs on any hardware, Whisper needs GPU. |
| **Vector** over Filebeat/Loki | Filebeat (Elastic stack) | Single Rust binary (5MB), zero GC, built-in backpressure, VRL transform language |
| **VictoriaMetrics** over Prometheus | Prometheus (more popular) | Single binary (20MB), Prometheus is ~300MB with full state. Same protocol. |
| **SQLite WAL** over PostgreSQL | PostgreSQL (production-grade) | Zero server process. For sandbox scale (1000s of TPS), WAL mode handles it. PostgreSQL adds 100MB+ RAM. |
| **Rootless Podman** over Docker | Docker (more common) | Daemonless, no privileged ports, no security risks. Compose syntax is compatible. |
| **Custom Osmocom Dockerfile** over pre-built image | docker-playground (complex) | No `osmo-msc-latest` image exists on any registry. Our build: 2-layer Dockerfile, apt install from Debian repos, no source compilation. |
