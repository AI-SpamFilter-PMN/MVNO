# Deployment and Configuration Guide — MVNO Core

This guide covers the transaction flow, software prerequisites, and complete configuration files for deploying the MVNO Core using both the **Native (systemd)** and **Containerized (Podman Compose)** methods.

---

## 1. Project Transaction Flow & Steps

[![MVNO Core Flow Chart](architecture_flow.png)](architecture_flow.svg)

### IMS VoLTE / VoNR Voice Call Signaling Flow

[![IMS Voice Call Interception Flow](ims_voice_call_flow.png)](ims_voice_call_flow.svg)

### SMS Store-and-Forward Interception Signaling Flow

[![SMS Interception Flow](sms_interception_flow.png)](sms_interception_flow.svg)

### Voice Transaction Steps:
1. **SIP Invite**: `UE_1` sends an `INVITE` request to Kamailio.
2. **Media Path Setup**: Kamailio proxies the signaling, registers the call location in the SQLite database, and calls `rtpengine` to bind media ports.
3. **Media Forking**: When the call starts, `rtpengine` forwards the media (RTP streams) between clients in-kernel and forks a raw copy of the audio to the spool directory `/var/spool/rtpengine`.
4. **Offline Translation**: `NativeVoskService.java` inside the Spring Boot Gateway detects the audio capture, transcribes it in-memory using native Java 21 Vosk JNI bindings (`com.alphacephei:vosk`), and extracts voice biometrics.
5. **AI Filtration Check**: The Spring Boot Gateway queries the external AI Filtration System's REST API. If the call contains spam, the number is blacklisted.

### SMS Transaction Steps:
1. **SMS Submit**: The SMS Client sends an SMS via SMPP to `OsmoSMSC`.
2. **Hold & Verification**: `OsmoSMSC` holds delivery and calls the Spring Boot Gateway's `/api/v1/intercept/sms` endpoint.
3. **AI Check & Delivery**: Spring Boot forwards the content to the AI Filtration system. If approved, `allow: true` is returned and `OsmoSMSC` delivers the message. If spam, it is dropped.

---

## 2. Software Prerequisites

### Method A: Native (systemd)
Deploying directly onto a Debian-slim/Ubuntu 22.04 LTS host:

| Component | Package / Source | Command to Install |
| :--- | :--- | :--- |
| **Kamailio** | Debian/Ubuntu packages | `sudo apt install kamailio kamailio-sqlite-modules` |
| **rtpengine** | Packages / Source | `sudo apt install ngcp-rtpengine ngcp-rtpengine-daemon` |
| **Osmocom** | Osmocom OBS repositories | `sudo apt install osmo-msc osmo-hlr` |
| **Vosk STT** | Native Java JNI (`com.alphacephei:vosk`) | Built-in via Maven dependency in `telecom-api` |
| **Spring Boot** | Java 21 LTS + Maven 3.9.9 | `./mvnw spring-boot:run` |
| **Vector** | Vector deb repo | `sudo apt install vector` |
| **VictoriaMetrics**| Pre-compiled binary | Download from GitHub releases |
| **Grafana** | Grafana APT repo | `sudo apt install grafana` |

### Method B: Containerized (Podman Compose + Docker Compose Plugin)
Operating in a daemonless, rootless environment:

| Tool | Version / Source | Why |
| :--- | :--- | :--- |
| **Podman** | `sudo apt install podman` | Daemonless rootless engine |
| **Docker Compose Plugin**| `sudo apt install docker-compose` | Compose orchestration via `podman compose` |

### Kernel Prerequisites (5G NGAP Signaling)

5G N2 interface signaling between UERANSIM gNB (`mvno-ueransim-gnb`) and Open5GS AMF (`mvno-amf`) over TCP/SCTP port 38412 requires the **SCTP kernel module** enabled on the host operating system:

```bash
# 1. Load SCTP kernel module
sudo modprobe sctp

# 2. Verify SCTP module state
lsmod | grep sctp

# 3. Install SCTP development headers & tools (pick your distro)
sudo apt install -y lksctp-tools      # Debian/Ubuntu
sudo dnf install -y lksctp-tools      # Fedora/RHEL
sudo pacman -S --needed lksctp-tools  # Arch/CachyOS
```
| **Podman API Socket**| `systemctl --user enable --now podman.socket` | Required by Docker Compose Plugin to talk to Podman |
| **Kamailio Image** | `mvno-kamailio:5.7.2` | Custom Alpine build (adds kamailio-utils) from `configs/kamailio/Dockerfile` |
| **rtpengine Image**| `drachtio/rtpengine:mr9.4.0.0` | Media engine container |
| **Osmocom Image** | `mvno-osmo-smsc:1.0.0` | Custom Debian build from `configs/osmocom/Dockerfile` |
| **Spring Boot Image** | `mvno-telecom-api:1.0.0` | Custom multi-stage Maven/Temurin build from `telecom-api/Dockerfile` (Java 21 LTS + Native Vosk) |
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

### B. Containerized (Podman Compose) Configuration Profiles

The stack uses two compose files:

| File | Purpose |
|------|---------|
| `docker-compose.yml` | **Offline-first** — just `image:` references, no build stanzas |
| `docker-compose.build.yml` | Override that adds `build:` stanzas for source compilation |

Default (`podman compose up -d`) uses pre-loaded images. To build from source:
```bash
podman compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The `docker-compose.yml` is configured for **rootless Podman** execution:
- Host port mappings are above `1024` to prevent permission errors.
- SELinux contexts are dynamically modified using `:z` volume flags.
- Databases use strict RAM caps suitable for unprivileged execution.

#### [docker-compose.yml](file:///home/zkhattab/MVNO/docker-compose.yml)

```yaml
networks:
  mvno_net:
    driver: bridge
    ipam:
      config:
        - subnet: 10.89.0.0/24

services:
  mongodb:
    image: mongo:7.0
    container_name: mvno-mongodb
    command: mongod --wiredTigerCacheSizeGB 0.25
    ports:
      - "27017:27017"
    volumes:
      - ./state/mongodb:/data/db:z
    networks:
      - mvno_net
    restart: unless-stopped

  open5gs-webui:
    image: mvno-open5gs-webui:2.8.0
    container_name: mvno-open5gs-webui
    ports:
      - "9999:3000"
    environment:
      - DB_URI=mongodb://mongodb:27017/open5gs
      - HOST=0.0.0.0
      - PORT=3000
      - NODE_PATH=src
    depends_on:
      mongodb:
        condition: service_healthy
    networks:
      - mvno_net
    restart: unless-stopped

  nrf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-nrf
    environment:
      COMPONENT_NAME: nrf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/nrf.yaml:/etc/open5gs/nrf.yaml:z
    depends_on:
      mongodb:
        condition: service_healthy
    networks:
      - mvno_net
    restart: unless-stopped

  amf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-amf
    environment:
      COMPONENT_NAME: amf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/amf.yaml:/etc/open5gs/amf.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  smf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-smf
    environment:
      COMPONENT_NAME: smf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/smf.yaml:/etc/open5gs/smf.yaml:z
    depends_on:
      nrf:
        condition: service_started
      upf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  upf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-upf
    environment:
      COMPONENT_NAME: upf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/upf.yaml:/etc/open5gs/upf.yaml:z
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  ausf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-ausf
    environment:
      COMPONENT_NAME: ausf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/ausf.yaml:/etc/open5gs/ausf.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  bsf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-bsf
    environment:
      COMPONENT_NAME: bsf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/bsf.yaml:/etc/open5gs/bsf.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  udm:
    image: mvno-open5gs:2.8.0
    container_name: mvno-udm
    environment:
      COMPONENT_NAME: udm
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/udm.yaml:/etc/open5gs/udm.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  udr:
    image: mvno-open5gs:2.8.0
    container_name: mvno-udr
    environment:
      COMPONENT_NAME: udr
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/udr.yaml:/etc/open5gs/udr.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  pcf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-pcf
    environment:
      COMPONENT_NAME: pcf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/pcf.yaml:/etc/open5gs/pcf.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  nssf:
    image: mvno-open5gs:2.8.0
    container_name: mvno-nssf
    environment:
      COMPONENT_NAME: nssf
      DB_URI: mongodb://mongodb/open5gs
    volumes:
      - ./configs/open5gs/nssf.yaml:/etc/open5gs/nssf.yaml:z
    depends_on:
      nrf:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  ueransim-gnb:
    image: mvno-ueransim:3.2.6
    container_name: mvno-ueransim-gnb
    command: ["nr-gnb", "-c", "/etc/ueransim/gnb.yaml"]
    volumes:
      - ./configs/ueransim/gnb.yaml:/etc/ueransim/gnb.yaml:z
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    depends_on:
      amf:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "cat /proc/net/sctp/assocs 2>/dev/null | grep -q 38412"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks:
      - mvno_net
    restart: unless-stopped

  ueransim-ue-1:
    image: mvno-ueransim:3.2.6
    container_name: mvno-ueransim-ue-1
    command: ["nr-ue", "-c", "/etc/ueransim/ue.yaml"]
    volumes:
      - ./configs/ueransim/ue.yaml:/etc/ueransim/ue.yaml:z
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    depends_on:
      ueransim-gnb:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  ueransim-ue-2:
    image: mvno-ueransim:3.2.6
    container_name: mvno-ueransim-ue-2
    command: ["nr-ue", "-c", "/etc/ueransim/ue.yaml"]
    volumes:
      - ./configs/ueransim/ue-spam.yaml:/etc/ueransim/ue.yaml:z
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    depends_on:
      ueransim-gnb:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  ueransim-ue-3:
    image: mvno-ueransim:3.2.6
    container_name: mvno-ueransim-ue-3
    command: ["nr-ue", "-c", "/etc/ueransim/ue.yaml"]
    volumes:
      - ./configs/ueransim/ue-zero.yaml:/etc/ueransim/ue.yaml:z
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    depends_on:
      ueransim-gnb:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  rtpengine:
    image: drachtio/rtpengine:mr9.4.0.0
    container_name: mvno-rtpengine
    command:
      - rtpengine
      - --config-file=/etc/rtpengine/rtpengine.conf
      - --listen-http=9900
    ports:
      - "30000-30100:30000-30100/udp"
      - "9900:9900"
    volumes:
      - ./configs/rtpengine:/etc/rtpengine:z
      - ./state/spool:/var/spool/rtpengine:z
    networks:
      - mvno_net
    restart: unless-stopped

  kamailio:
    image: mvno-kamailio:5.7.2
    container_name: mvno-kamailio
    ports:
      - "5066:5060/udp"
    volumes:
      - ./configs/kamailio:/etc/kamailio:z
      - ./state/kamailio/kamailio.db:/etc/kamailio/kamailio.db:z
    depends_on:
      rtpengine:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  osmo-hlr:
    image: mvno-osmo-smsc:1.0.0
    container_name: mvno-osmo-hlr
    command: osmo-hlr -c /etc/osmocom/osmo-hlr.cfg
    volumes:
      - ./configs/osmocom:/etc/osmocom:z
      - ./state/hlr:/var/lib/osmocom:z
    healthcheck:
      test: ["CMD-SHELL", "timeout 3 bash -c 'echo > /dev/tcp/localhost/4222' 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      mvno_net:
        ipv4_address: 10.89.0.45
    restart: unless-stopped

  osmo-smsc:
    image: mvno-osmo-smsc:1.0.0
    container_name: mvno-osmosmsc
    ports:
      - "2775:2775"
    volumes:
      - ./configs/osmocom:/etc/osmocom:z
      - ./state/hlr:/var/lib/osmocom:z
    depends_on:
      - osmo-hlr
    healthcheck:
      test: ["CMD-SHELL", "timeout 3 bash -c 'echo > /dev/tcp/localhost/2775' 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - mvno_net
    restart: unless-stopped

  telecom-api:
    image: mvno-telecom-api:1.0.0
    container_name: mvno-api
    ports:
      - "8080:8080"
    volumes:
      - ./state/kamailio:/etc/kamailio:z
      - ./state/spool:/var/spool/rtpengine:z
    healthcheck:
      test: ["CMD-SHELL", "timeout 3 bash -c 'echo > /dev/tcp/localhost/8080' 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - mvno_net
    restart: unless-stopped

  ai-filter:
    image: python:3.11-alpine
    container_name: mvno-ai-filter
    ports:
      - "8008:8000"
    command:
      - python3
      - -c
      - |
        from http.server import HTTPServer, BaseHTTPRequestHandler
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get('Content-Length', 0))
                if length > 0: self.rfile.read(length)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"allow":true,"reason":"Clean content"}')
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'OK')
        HTTPServer(('0.0.0.0', 8000), H).serve_forever()
    networks:
      - mvno_net
    restart: unless-stopped

  vector:
    image: timberio/vector:0.44.0-alpine
    container_name: mvno-vector
    volumes:
      - ./configs/vector/vector.toml:/etc/vector/vector.toml:z
      - /run/user/${UID:-1000}/podman/podman.sock:/var/run/docker.sock:ro,z
    networks:
      - mvno_net
    restart: unless-stopped

  victoria-metrics:
    image: victoriametrics/victoria-metrics:v1.101.0
    container_name: mvno-victoriametrics
    ports:
      - "8428:8428"
    volumes:
      - ./state/vm-data:/victoria-metrics-data:z
    networks:
      - mvno_net
    restart: unless-stopped

  vmagent:
    image: victoriametrics/vmagent:v1.101.0
    container_name: mvno-vmagent
    ports:
      - "8429:8429"
    command:
      - "-remoteWrite.url=http://victoria-metrics:8428/api/v1/write"
      - "-promscrape.config=/etc/prometheus/prometheus.yml"
    volumes:
      - ./configs/victoria-metrics/scrape.yml:/etc/prometheus/prometheus.yml:z
    depends_on:
      victoria-metrics:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped

  grafana:
    image: grafana/grafana-oss:11.6.0
    container_name: mvno-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./configs/grafana/provisioning:/etc/grafana/provisioning:z
      - ./state/grafana:/var/lib/grafana:z
    depends_on:
      victoria-metrics:
        condition: service_started
    networks:
      - mvno_net
    restart: unless-stopped
```


**Integrated 5G SA Core & RAN Simulation Services**:
- Includes `mongodb` service (`mongo:7.0`) and 10 Open5GS NFs (`nrf`, `amf`, `smf`, `upf`, `udm`, `ausf`, `udr`, `pcf`, `nssf`, `bsf`)
- Includes `mvno-open5gs-webui` service for web subscriber management
- Includes containerized `ueransim` base image (`mvno-ueransim:3.2.6`) running `mvno-ueransim-gnb` and 3 simulated UEs (`mvno-ueransim-ue-1..3`)

---

## 4. Port Binding Summary

| Component | Target Port | Protocol | Usage | Podman Rootless Mode |
| :--- | :--- | :--- | :--- | :--- |
| **Kamailio** | `5066 (host) → 5060 (container)` | UDP / TCP | SIP signaling | Host port 5066 mapped to container port 5060 |
| **rtpengine** | `30000-30100` | UDP | Media plane (RTP) | Native bind (no changes) |
| **OsmoSMSC** | `2775` | TCP | SMPP SMS delivery | Native bind (no changes) |
| **Spring Boot** | `8080` | TCP | Interception REST API + actuator health | Native bind (no changes) |
| **VictoriaMetrics** | `8428` | TCP | Metrics ingestion | Native bind (no changes) |
| **vmagent** | `8429` | TCP | Metrics scraping agent target API | Mapped to host port `8429` for target inspection |
| **Grafana** | `3000` | TCP | NOC dashboard | Native bind (no changes) |
| **MongoDB** (Phase 3+) | `27017` | TCP | Open5GS subscriber metadata | Native bind (no changes) |
| **Open5GS NRF** (Phase 3+) | `7777` | TCP | 5GC service registry | Native bind (no changes) |
| **Vector** | — | — | Log shipper (no exposed ports) | Internal only |
| **Open5GS WebUI** | `9999` | TCP | Subscriber & SIM Management WebUI | Native bind (`9999:3000`) |

---

## 5. Web Dashboards & Admin Access Credentials

### 📊 Grafana Real-Time Telecom NOC Dashboard
- **Web UI URL:** `http://localhost:3000`
- **Username:** `admin`
- **Password:** `admin`
- **Provisioned NOC Dashboards:**
  1. `MVNO Interception Core — Unified Master NOC Dashboard` (`uid: mvno-unified-noc`)
  2. `NOC Overview` (`uid: noc-overview`)
  3. `NOC Telecom API` (`uid: noc-telecom-api`)
  4. `NOC RTPEngine` (`uid: noc-rtpengine`)
- **Verification Status:** Validated via HTTP `POST /login` (`HTTP 200 OK`, `grafana_session` cookie issued).

### 📱 Open5GS 5G SA Subscriber Management WebUI
- **Web UI URL:** `http://localhost:9999`
- **Username:** `admin`
- **Password:** `1423`
- **Database Binding:** `mongodb://mvno-mongodb:27017/open5gs`
- **Admin Account Hashing:** Account document seeded in MongoDB collection `open5gs.accounts`:
  ```json
  {
    "username": "admin",
    "password": "$2b$12$L6PO5GJQfMmHt6Uall2OxODicgdosZohXDvwS1HPt/Q.WXUD92Y7S",
    "roles": ["admin"]
  }
  ```
- **Verification Status:** Validated bcrypt cost 12 hash salt for password `1423` seeded directly into MongoDB `open5gs` database.

---

## 6. MVNO Core Integration Flow & Steps

This section details the step-by-step runbook to integrate your MVNO core components with each other and connect them to the AI Filtration REST APIs.

### Step 1: Database Setup and SQLite Hardening
Initialize the database files and configure them for high concurrency (WAL Mode) before booting any core services:
1. **Initialize databases**: Use `make init-db` to create the SQLite databases with WAL mode and the subscriber table:
   ```bash
   make init-db
   ```
   This creates `state/kamailio/kamailio.db` (subscriber registry) and `state/hlr/hlr.db` (OsmoHLR subscriber data) with WAL PRAGMAs applied and test subscribers inserted.

2. **Verify**:
   ```bash
   sqlite3 state/kamailio/kamailio.db "SELECT username, msisdn, balance FROM subscriber;"
   # Expected: 15551234567 | 15551234567 | 100
   #           15557654321 | 15557654321 | 0
   ```

### Step 2: Establish the Media Plane Connection (Kamailio ↔ rtpengine)
Link the signaling server (Kamailio) with the packet forwarding proxy (rtpengine):
1. **Set rtpengine NG listen port**: In `configs/rtpengine/rtpengine.conf`, the NG control socket listens on port `22222` (UDP, container-internal):
   ```ini
   listen-ng = 0.0.0.0:22222
   ```
   > **Media Plane Performance Note**: RTPEngine operates in userspace daemon mode under unprivileged rootless Podman execution (`--foreground`). For kernel-bypass hardware acceleration (`xt_RTPENGINE`), mount `/dev/rtpengine` character device with root privileges.
2. **Configure Kamailio module**: In `configs/kamailio/kamailio.cfg`, load the module and point it to the rtpengine container:
   ```kamailio
   loadmodule "rtpengine.so"
   modparam("rtpengine", "rtpengine_sock", "udp:rtpengine:22222")
   ```
   Note: In containers, use the service hostname (`rtpengine`), not `127.0.0.1`.

3. **Trigger media redirection**: Within Kamailio's call route, invoke rtpengine to manage the stream:
   ```kamailio
   route[RTPCALL] {
       if (is_method("INVITE") && has_body("application/sdp")) {
           rtpengine_manage("record-call=yes metadata=JSON");
       }
   }
   ```

### Step 3: Link Interception Webhooks (Core ↔ Spring Boot Gateway)
Configure the signaling systems to call the API Gateway for approval before routing traffic:
1. **SMS Interception**: In `osmo-smsc.cfg`, the Spring Boot gateway acts as an SMPP ESME client. Configure the gateway's SMPP connection in the application settings. The gateway connects to `osmo-smsc:2775` and issues `SUBSCRIBE_SM` for delivery reports. The actual SMS routing happens via the gateway's `/api/v1/intercept/sms` REST endpoint, called by a Kamailio HTTP POST.

2. **Call Interception**: In `kamailio.cfg`, the gateway is queried via HTTP POST during the INVITE handling:
   ```kamailio
   # http_client.so is loaded and used in kamailio.cfg for HTTP REST callouts.
   # The gateway URL uses the container hostname:
   #   http://mvno-api:8080/api/v1/intercept/call
   ```
   See `configs/kamailio/kamailio.cfg` `route[INTERCEPT]` for the full implementation.

### Step 4: Speech Translation Pipeline (rtpengine ↔ NativeVoskService ↔ AI Filter)
The ASR pipeline runs **entirely inside the Spring Boot JVM** via `NativeVoskService.java` — there is no external Python worker.

1. **Set shared spool**: Point rtpengine's recording path to the shared volume mount in `rtpengine.conf`:
   ```ini
   recording-dir = /var/spool/rtpengine
   recording-method = fork
   recording-format = wav
   ```
   > **Note:** rtpengine streams audio captures via fork recording mode to `/var/spool/rtpengine`.

2. **Native Java 21 Vosk ASR** (`NativeVoskService.java` inside `mvno-api`):
   - Uses a `@Scheduled(fixedDelay = 3000)` virtual-thread task that polls `/var/spool/rtpengine` every 3 seconds.
   - When a `.wav` file is ready, it is decoded in-memory using native JNI bindings (`com.alphacephei:vosk:0.3.45`) — zero Python, zero cloud.
   - The transcript + biometrics are `POST`-ed to `POST /api/v1/transcriptions` (same JVM, loopback).
   - The gateway then routes the result to the AI Spam Model REST API for allow/block decisions.
   - **No separate `vosk-worker` container is needed** — this is handled entirely by `mvno-api`.

### Step 5: Observability Aggregation (vmagent ↔ VictoriaMetrics)
Connect the lightweight time-series stack to scrape metrics:
1. **Define target profiles**: In `configs/victoria-metrics/scrape.yml`, configure scraping parameters. All targets use container hostnames, not `127.0.0.1`:
   ```yaml
   scrape_configs:
     - job_name: 'telecom-api'
       static_configs:
         - targets: ['mvno-api:8080']
     - job_name: 'rtpengine'
       static_configs:
         - targets: ['rtpengine:9900']
     - job_name: 'vmagent'
       static_configs:
         - targets: ['vmagent:8429']
   ```
2. **Set ingestion write-path**: Point `vmagent` to push all aggregated telemetry to the VictoriaMetrics TSDB single-binary database at `victoria-metrics:8428`.

---

## 7. Makefile Targets

All developer lifecycle operations are in the `Makefile`:

| Target | Command | Purpose |
|---|---|---|
| `make init-db` | `sqlite3 state/kamailio/kamailio.db ...` | Initialize SQLite WAL databases + seed test subscribers |
| `make up` | `podman compose up -d --build` | Start the full stack |
| `make down` | `podman compose down` | Stop all containers |
| `make ps` | `podman ps` | List running containers |
| `make logs` | `podman compose logs -f` | Stream all container logs |
| `make test-api` | `curl /actuator/health/liveness` | Verify gateway health |
| `make test-sms` | SMPP test via Python `smpplib` | End-to-end SMS intercept test |
| `make test-call` | SIPp scenario | SIP call intercept test |
| `make clean` | `rm -rf state/*` | Wipe all state data |
| `make rebuild` | `clean + init-db + up` | Full teardown and rebuild |

