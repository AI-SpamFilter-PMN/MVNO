# MVNO Core — Best Practices & SOTA Additions
_Augmenting the 5 existing practices without exceeding lightweight/optimized constraints_

---

## Already Adopted (the 5 from previous answer)

| # | Practice | Status |
|---|----------|--------|
| 1 | On-Demand Activation (`restart: "no"` + `systemctl disable`) | Adopted |
| 2 | Tiny Python log exporter (no Filebeat/Logstash) | Adopted |
| 3 | Plaintext IMSI exposure detection via regex | Adopted |
| 4 | Sovereign Makefile orchestration | Adopted |
| 5 | Static config validation script (`validate_configs.py`) | Adopted |

---

## NEW Best Practices — SOTA & Industry Gold Standard

---

### 6. Upgrade RTP Proxy: `rtpproxy` → `rtpengine` (SOTA Media Plane)

**Category:** Telecom Core / Media Plane
**Footprint impact:** Neutral — same resource class, much more capable

The industry has moved from `rtpproxy` to **`rtpengine`** as the gold standard for Kamailio media relay.

| Feature | rtpproxy (old) | rtpengine (SOTA) |
|---------|---------------|-----------------|
| Packet forwarding | Userspace only | **In-kernel via DKMS module** (near-zero CPU) |
| Call recording | File copy | **Native media forking + SIPREC** |
| WebRTC/SRTP | Limited | **Native: ICE, DTLS-SRTP** |
| Kamailio integration | Loose | **Tight: native `rtpengine` module** |
| IPv4/IPv6 bridging | Manual | **Automatic** |

**Why it directly matters here:**
- `rtpengine`'s in-kernel forwarding offloads RTP packet processing from the CPU entirely. When a call is active, RTP traffic bypasses the userspace daemon completely after the initial setup — this is the opposite of adding overhead.
- Native media forking means recorded audio streams are cleanly split and written to disk for Vosk without a secondary recording daemon.
- SIPREC (Session Recording Protocol, RFC 7866) support means the call recording is done in a standards-compliant way, making the recorded stream directly consumable by the AI Filtration REST API.

**Zero new containers or processes needed** — it is a direct replacement for `rtpproxy`.

---

### 7. Replace Python log tail with Vector.dev (Rust-based, Zero GC)

**Category:** Log Shipping / Observability
**Footprint impact:** ~5-15MB RAM idle (Rust binary, no GC pauses)

The Python `log_exporter.py` script is a great starting point, but it has a critical weakness: Python's GIL and garbage collector introduce latency spikes under bursty log volume (e.g., during a flood of SIP REGISTER attempts or an SMS spam burst — exactly when you need low-latency log delivery to the AI Filter most).

**Vector.dev** is a single Rust binary that replaces the Python log tailer:

```yaml
# vector.toml — minimal config for our MVNO stack
[sources.kamailio_logs]
  type = "file"
  include = ["/var/log/kamailio/kamailio.log"]

[sources.osmosmsc_logs]
  type = "file"
  include = ["/var/log/osmocom/osmo-msc.log"]

[transforms.parse_sip_events]
  type = "remap"
  inputs = ["kamailio_logs"]
  source = '''
    .event_type = "sip"
    .caller, .callee = parse_regex!(.message, r'From: <sip:(?P<caller>[^@]+).*To: <sip:(?P<callee>[^@]+)')
  '''

[sinks.filtration_api]
  type = "http"
  inputs = ["parse_sip_events"]
  uri = "http://filtration-api:8080/api/v1/events"
  method = "post"
  encoding.codec = "json"
```

**Why Vector over keeping Python:**
- Written in Rust → no GC, no GIL, deterministic sub-millisecond latency
- VRL (Vector Remap Language) is purpose-built for log parsing and is more reliable than ad-hoc regex in Python
- Built-in **backpressure handling**: if the Filtration API is temporarily down, Vector buffers events to disk and replays them — the Python script would silently drop them
- **Single static binary** — no pip, no venv, no dependency management

> [!NOTE]
> Keep `validate_configs.py` and the Makefile in Python — those are one-shot scripts, not hot-path daemons. Only the always-on log tail should be replaced.

---

### 8. Kamailio Security Hardening: PIKE + HTable + nftables (Zero RAM Cost)

**Category:** SIP Security / Network Hardening
**Footprint impact:** Zero — pure Kamailio config + kernel firewall rules

This is a SOTA three-layer SIP defense that every production Kamailio deployment uses.

#### Layer 1 — PIKE Module (Per-IP Rate Limiting at Application Layer)
Detects IPs sending more SIP requests than a threshold within a time window and blocks them:

```kamailio
# kamailio.cfg — add to top of request_route
loadmodule "pike.so"
loadmodule "htable.so"

modparam("pike", "sampling_time_unit", 5)
modparam("pike", "reqs_density_per_unit", 30)  # block if >30 req/5s from same IP
modparam("htable", "htable", "ban=>size=8;autoexpire=300;")

route[REQINIT] {
    if ($sht(ban=>$si) == 1) {
        xlog("L_WARN", "Blocked banned IP: $si\n");
        exit;
    }
    if (!pike_check_req()) {
        xlog("L_WARN", "PIKE: rate limit exceeded for $si — banning\n");
        $sht(ban=>$si) = 1;
        exit;
    }
}
```

#### Layer 2 — Topology Hiding (`topoh` module)
Hides internal network structure (private IPs, internal hostnames) from SIP messages leaving the network. Prevents reconnaissance by attackers enumerating the internal topology.

#### Layer 3 — nftables (Kernel-Level Firewall, replaces iptables)
`nftables` is the official successor to `iptables` on all modern Linux distros (Ubuntu 22.04+, the likely deploy target). It uses $O(\log n)$ set lookups vs `iptables`'s $O(n)$ linear scan — critical when banning large numbers of IPs:

```nft
# /etc/nftables.conf — minimal telecom ruleset
table inet mvno_firewall {
  set banned_ips {
    type ipv4_addr
    flags dynamic, timeout
    timeout 5m
  }

  chain sip_filter {
    type filter hook input priority 0; policy accept;
    ip saddr @banned_ips drop comment "PIKE-banned IPs"
    udp dport 5060 limit rate 100/second burst 200 packets accept
    udp dport 5060 drop comment "SIP flood protection"
  }
}
```

**Integration point:** The Kamailio PIKE module writes to `htable`; a tiny shell script called by Kamailio's `exec` module can add IPs to the nftables set atomically — kernel-level blocking within milliseconds of detection.

---

### 9. SQLite WAL Mode Hardening (Official Osmocom + Kamailio Tuning)

**Category:** Database / Reliability
**Footprint impact:** Zero overhead — pure PRAGMA configuration

Both OsmoHLR and Kamailio's db_sqlite already support WAL mode — confirmed by official Osmocom source code and Kamailio docs. This should be set as the **mandatory default** in all config files:

```sql
-- Apply once on database initialization (or in startup script)
PRAGMA journal_mode = WAL;       -- enables concurrent reads during writes
PRAGMA synchronous = NORMAL;     -- reduces fsync calls; safe in WAL mode
PRAGMA busy_timeout = 5000;      -- wait 5s on lock before failing
PRAGMA cache_size = -2000;       -- 2MB page cache (negative = kilobytes)
PRAGMA temp_store = MEMORY;      -- keep temp tables in RAM, not disk
```

**Why this matters for our use case:**
The AI Filtration System will be making concurrent reads (checking blacklists) at the same time Kamailio is writing new SIP registrations. Without WAL mode, these operations would block each other. With WAL mode, reads and writes proceed concurrently without locking — directly improving SMS/call throughput under spam-flood conditions.

---

### 10. SMPP Hardening: TLS + Rate Limiting + Quarantine Queue

**Category:** SMS Security / SMPP Protocol
**Footprint impact:** Zero — configuration changes only

Industry standard SMPP hardening for a spam-filtering MVNO:

**a) SMPP over TLS**
OsmoSMSC supports SMPP over TLS for connections from external SMS clients. Enable this to prevent man-in-the-middle interception of SMS content in transit between the SMS Client and OsmoSMSC.

**b) Per-ESME TPS (Transactions Per Second) Limits**
In `osmo-smsc.cfg`, configure per-connection rate limits:
```
smpp
 local-tcp-ip 0.0.0.0 2775
 system-id MVNO_SMSC
 max-pending-requests 100       ← queue depth before throttle error
```

**c) Quarantine Queue Pattern (not hard-block)**
Instead of immediately dropping suspected spam SMS at the SMSC level, route high-suspicion messages to a **quarantine queue** — a separate SQLite table — before the AI Model classifies them. This eliminates false positives where a legitimate message is permanently lost. The AI Filter reads from the quarantine queue, classifies, then either delivers or discards.

```
Normal SMS → OsmoSMSC → [Filtration REST API]
                              ↓           ↓
                        Allow → Deliver  Suspicious → Quarantine Queue → AI Model → Decision
```

---

### 11. FastAPI for the REST API Layer (Lightweight Python ASGI)

**Category:** REST API / Integration Layer
**Footprint impact:** ~30-60MB RAM — far lighter than Spring Boot (~300MB+)

Since our REST API layer is the bridge between the MVNO core and the AI Filtration System, and since we are not bound to Java (unlike your GitLab project which uses Spring Boot for billing), **FastAPI** is the SOTA lightweight choice:

- **ASGI + async:** Handles concurrent requests from Kamailio (call checks) and OsmoSMSC (SMS checks) simultaneously without threading overhead
- **Auto-generated OpenAPI docs:** `/docs` endpoint gives the AI Filtration team a live Swagger UI to inspect and test the API without additional tooling
- **Pydantic validation:** All incoming event payloads (caller MSISDN, SMS body, transcript text) are schema-validated before reaching the AI model
- **Two mandatory health endpoints** per industry standard:

```python
# health.py — liveness vs readiness (industry gold standard)
@router.get("/live")   # lightweight: just confirms process is alive
async def liveness():
    return {"status": "alive"}

@router.get("/ready")  # heavyweight: checks all dependencies
async def readiness():
    checks = await asyncio.gather(
        check_sqlite_connection(),
        check_filtration_api_reachable(),
        return_exceptions=True
    )
    healthy = all(not isinstance(c, Exception) for c in checks)
    status_code = 200 if healthy else 503
    return JSONResponse({"status": "ready" if healthy else "degraded"}, status_code=status_code)
```

---

### 12. Secret / Credential Management — `.env` + `systemd` Credentials (Never Hardcode)

**Category:** Security / DevOps
**Footprint impact:** Zero

A critical industry practice that is often skipped in lab/graduation projects but makes the difference between a professional and amateur codebase:

**Never hardcode** SMPP passwords, MongoDB credentials, API keys, or IMSI/Ki values in config files committed to Git.

**Two-tier approach:**
- **Native deployment:** Use `systemd` credential files (`LoadCredential=`) which bind secrets to the unit lifecycle and are only accessible by the running service process
- **Container deployment:** Use a `.env` file (gitignored) loaded by Docker/Podman Compose:

```yaml
# docker-compose.yml
services:
  osmo-smsc:
    env_file: .env          # loads SMPP_PASSWORD, DB_PATH etc.
    environment:
      - SMPP_SYSTEM_ID=${SMPP_SYSTEM_ID}
```

```bash
# .env (gitignored — never committed)
SMPP_SYSTEM_ID=MVNO_SMSC
SMPP_PASSWORD=changeme_in_production
MONGO_URI=mongodb://localhost:27017/open5gs
FILTRATION_API_KEY=secret_token
```

```
# .gitignore
.env
*.sqlite
*.db
hlr.db
```

---

### 13. Startup Dependency Ordering (Graceful Sequenced Boot)

**Category:** Reliability / Operations
**Footprint impact:** Zero — pure Compose/systemd configuration

One of the most common failure patterns in multi-component telecom stacks (confirmed by your GitLab README Risk #8: "MongoDB not started when Open5GS launches") is services starting before their dependencies are ready.

**For Compose (Docker/Podman):**
```yaml
services:
  mongodb:
    image: mongo:8.0
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.runCommand({ping:1})", "--quiet"]
      interval: 5s
      timeout: 3s
      retries: 5

  open5gs-nrf:
    depends_on:
      mongodb:
        condition: service_healthy   # waits for healthcheck to pass, not just start

  kamailio:
    depends_on:
      open5gs-nrf:
        condition: service_healthy
```

**For Native (systemd):**
```ini
# /etc/systemd/system/osmo-smsc.service
[Unit]
After=network-online.target osmo-msc.service
Requires=osmo-msc.service
```

This eliminates entire categories of startup race condition bugs with zero runtime cost.

---

## Consolidated RAM Budget (Optimized Stack)

| Component | Idle RAM | Active RAM | Notes |
|-----------|----------|------------|-------|
| Kamailio | ~15MB | ~30-50MB | With PIKE + HTable loaded |
| rtpengine | ~8MB | ~20MB | Kernel offload reduces active CPU, not RAM |
| OsmoSMSC | ~10MB | ~15MB | SQLite WAL mode |
| Vosk STT | 0MB (on-demand) | ~150-300MB | Only active during calls |
| Vector.dev | ~5MB | ~8MB | Rust binary, no GC |
| VictoriaMetrics | ~20MB | ~40MB | Single-node |
| vmagent | ~8MB | ~12MB | Scrape agent |
| Grafana | ~80MB | ~100MB | Dashboard only |
| MongoDB (Open5GS) | ~350MB | ~500MB | WiredTiger capped at 0.25GB |
| FastAPI REST | ~30MB | ~60MB | Async ASGI |
| **Total (idle)** | **~526MB** | | |
| **Total (1 active call)** | **~726-876MB** | | Vosk active |

---

## Advanced SOTA MVNO Core Enhancements (Lightweight & High-Value)

These additional telecom core enhancements further elevate the project's security and capabilities for evaluation panels with zero impact on idle RAM overhead.

---

### 14. Caller ID Anti-Spoofing Gateway (STIR/SHAKEN Simulation)
*   **Concept**: Caller ID spoofing is a major security vulnerability in telephony where spammers pretend to call from legitimate numbers (banks, government agencies).
*   **Lightweight Implementation**: 
    - In `kamailio.cfg` and `osmo-smsc.cfg`, intercept calls/SMS before they are routed.
    - Check the SIP `From` header / SMPP source address against the authenticated client's actual registered MSISDN bound in the local SQLite table.
    - If they mismatch (e.g., an authenticated subscriber at `+12345` attempts to place a call using caller ID `+99999`), Kamailio drops the request immediately, returning a SIP `407 Proxy Authentication Required` error without contacting the AI filter.
*   **eTOM Alignment**: **Service Security Management & Fraud Prevention**.

---

### 15. WebRTC & SRTP/TLS Transcoding (Signaling & Media Encryption)
*   **Concept**: Standard SIP/RTP sends packets in cleartext. SOTA mobile networks require TLS for signaling and SRTP for media.
*   **Lightweight Implementation**:
    - Configure Kamailio's `tls.cfg` to handle SIP over TLS on TCP port 5061 using local certificates.
    - Configure `rtpengine` to perform transparent **SRTP-to-RTP transcoding**. When a secure user makes a call, rtpengine decrypts the SRTP stream on the fly and saves the cleartext audio `.wav` file into the local Vosk spool directory.
    - This provides full security over the air (SIP-TLS / SRTP) while still allowing the backend Vosk STT engine to read the unencrypted voice data for spam analysis.

---

### 16. Captcha/Spam honeypot IVR (Interactive Voice Response)
*   **Concept**: When the AI filter receives a call check request and determines a medium-suspicion rating, instead of an outright block or allow, it redirects the caller to a verification gateway.
*   **Lightweight Implementation**:
    - If the FastAPI gateway receives a medium-risk rating, it instructs Kamailio to return a redirect `rewrite_uri` to an internal IVR route.
    - Kamailio plays a simple prompt (e.g., *"Press 3 to complete your call"* or *"Please state your name and business after the beep"*).
    - The DTMF input or the brief voice response is captured and parsed by Vosk. If it passes verification, the call is bridged to the recipient. If it fails, the call is hung up. This implements an active voice CAPTCHA.

---

### 17. Local Fallback Caching (DDoS / Fail-Safe Protection)
*   **Concept**: If the AI Filtration System experiences downtime or a DDoS traffic burst, the MVNO core could experience latency waiting for API timeouts.
*   **Lightweight Implementation**:
    - Configure Kamailio's `http_client` module with a strict 1-second timeout.
    - If a connection timeout occurs, Kamailio falls back to checking a local, fast in-memory **HTable cache** of recently verified spam numbers and whitelist contacts, allowing standard traffic to proceed uninterrupted.
*   **eTOM Alignment**: **Service Availability & Business Continuity**.

---

### 18. Dynamic Vosk Language Model Hot-Caching
*   **Concept**: Loading heavy multilingual speech models simultaneously wastes RAM.
*   **Lightweight Implementation**:
    - Configure `vosk_worker.py` to parse the dialed country code.
    - If the call is local (English), load only the 40MB `vosk-model-small-en-us` model.
    - If the call is international (e.g., to an Arabic country code), load the corresponding small language model dynamically.
    - Keep only one model loaded in RAM at a time, performing hot-unloads of the inactive model to stay within your host VM's memory limits.

