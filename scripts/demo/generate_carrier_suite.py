#!/usr/bin/env python3
"""
generate_carrier_suite.py — Generates the Complete Tier-1 SOTA Telecom NOC Dashboard Suite
Industry Standards: 3GPP Rel-16, ETSI NFV-EVE, TM Forum Open Digital Architecture.

Suite Structure:
1. MVNO NOC — Unified (Executive Single-Pane of Glass)
2. MVNO SOC — AI Anti-Fraud & Cyber Security Mesh
3. MVNO 5G SA — Core Network & Data Plane Slicing
4. MVNO IMS — Voice Signaling & RTP Media Performance
5. MVNO VictoriaMetrics — Platform TSDB Infrastructure
"""
import json
import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
DASH_DIR = os.path.join(REPO_ROOT, "configs/grafana/provisioning/dashboards")
os.makedirs(DASH_DIR, exist_ok=True)

DS_VM = {"type": "prometheus", "uid": "victoriametrics"}
DS_VL = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}

# ==============================================================================
# 1. DASHBOARD: MVNO SOC — AI Anti-Fraud & Cyber Security Mesh
# ==============================================================================
def make_soc_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO SOC — AI Anti-Fraud & Cyber Security Mesh",
        "uid": "mvno-soc-antifraud",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["mvno", "plane:soc", "security", "anti-fraud", "sota", "stir-shaken", "dsp"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    
    # Hero KPI Row
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "🛡️ SECURITY OPERATIONS CENTER (SOC) — THREAT INTELLIGENCE SUMMARY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 1, "title": "🚨 Malicious SMS / Smishing Blocked", "description": "Smishing messages containing weaponized URLs or financial scams intercepted by AI.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#FF0055", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_sms_blocked_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 2, "title": "📞 Fraudulent Voice Calls Blocked", "description": "Robocalls, spoofed caller IDs, and fraud voice attempts blocked at Kamailio.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF5252", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#FF5252", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_call_blocked_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 3, "title": "🔍 5G UPF Phishing Intercepts", "description": "L7 DNS queries and TLS SNIs blocked on 5G user plane (ogstun 10.45.0.1).",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF9100", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#FF9100", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_dpi_threats_intercepted_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 4, "title": "🔐 EIR SIM-Swap Violations", "description": "IMSI/IMEI binding mismatches flagged by Equipment Identity Register.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#7928CA", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#7928CA", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(eir_sim_swaps_detected_total) default 0", "refId": "A"}]
    })

    # Deep Packet & AI Voice Row
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "🧠 AI ACOUSTIC SPEECH & VOICE CLONE DETECTION PIPELINE", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 5, "title": "🔑 Transcribed Scam & Phishing Keywords (Vosk ASR)", "description": "Frequency of high-risk banking/phishing phrases detected in live call audio.",
        "type": "bargauge", "gridPos": {"h": 8, "w": 12, "x": 0, "y": 6},
        "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF9100", "value": 2}, {"color": "#FF0055", "value": 5}]}, "unit": "short"}},
        "options": {"displayMode": "gradient", "orientation": "horizontal", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "showUnfilled": True},
        "targets": [{"datasource": DS_VM, "expr": "sum by (keyword) (mvno_speech_keyword_hits_total)", "legendFormat": "{{keyword}}", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "⚡ AI ASR Transcription Velocity & Latency", "description": "Rate of real-time speech segments processed by offline Vosk ASR JNI.",
        "type": "timeseries", "gridPos": {"h": 8, "w": 12, "x": 12, "y": 6},
        "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 15, "lineWidth": 2}, "unit": "short"}},
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_speech_transcriptions_total) default 0", "legendFormat": "Transcriptions", "refId": "A"}]
    })

    # Security Logs Row
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14}, "id": 30, "title": "📋 REAL-TIME THREAT INTERCEPTION STREAM (VICTORIALOGS)", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VL, "id": 7, "title": "🔍 Live Security & Fraud Neutralization Events", "description": "Structured log stream of blocked SMS, fraud robocalls, and 5G DPI alerts.",
        "type": "logs", "gridPos": {"h": 10, "w": 24, "x": 0, "y": 15},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}}},
        "options": {"dedupStrategy": "none", "enableLogDetails": True, "showLabels": True, "showTime": True, "sortOrder": "Descending", "wrapLogMessage": True},
        "targets": [{"datasource": DS_VL, "expr": "* | \"BLOCKED\" or \"FRAUD\" or \"DPI-ALERT\"", "refId": "A"}]
    })

    return dash

# ==============================================================================
# 2. DASHBOARD: MVNO 5G SA — Core Network & Data Plane Slicing
# ==============================================================================
def make_5g_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO 5G SA — Core Network & Data Plane Slicing",
        "uid": "mvno-5g-core-dpi",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["mvno", "plane:5g", "open5gs", "ueransim", "sota", "gtp-u", "dpi"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    
    # 5G KPIs
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "📡 5G STANDALONE (SA) CORE STATUS & RADIO METRICS", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 1, "title": "📱 Registered 5G UEs", "description": "Active 5G User Equipments registered to AMF over NGAP 38412.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#7928CA", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#7928CA", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "ran_ue default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 2, "title": "📶 Active 5G PDU Sessions (UPF)", "description": "Active GTP-U PDU user-plane sessions on Open5GS UPF (ogstun 10.45.0.1).",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "fivegs_upffunction_upf_sessionnbr default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 3, "title": "🔍 5G L7 Inspected Payload", "description": "Total user-plane payload decapsulated from GTP-U tunnels.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]}, "unit": "decbytes"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_dpi_bytes_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 4, "title": "⚡ 5G Core Functions (AMF/SMF/UPF)", "description": "Prometheus liveness of 5G SA Network Functions.",
        "type": "stat", "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#38BDF8", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#38BDF8", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "count(up{job=~\"open5gs-.*|5g-.*\"}) default 0", "refId": "A"}]
    })

    # DPI Traffic Breakdown
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "📈 5G USER-PLANE DEEP PACKET INSPECTION & PROTOCOL VELOCITY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 5, "title": "📊 5G Application Flow Distribution (DNS / TLS / HTTP / RTP)", "description": "Current active packet flows tracked by protocol on ogstun.",
        "type": "stat", "gridPos": {"h": 6, "w": 10, "x": 0, "y": 6},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "mvno_dpi_flows_active", "legendFormat": "{{protocol}}", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "🌊 5G Decapsulated L7 User-Plane Bandwidth by Protocol", "description": "Time-series throughput of user-plane protocols decapsulated from GTP-U.",
        "type": "timeseries", "gridPos": {"h": 6, "w": 14, "x": 10, "y": 6},
        "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 15, "lineWidth": 2}, "unit": "decbytes"}},
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "sum by (protocol) (mvno_dpi_bytes_total)", "legendFormat": "{{protocol}}", "refId": "A"}]
    })

    return dash

# ==============================================================================
# 3. DASHBOARD: MVNO IMS — Voice Signaling & RTP Media Performance
# ==============================================================================
def make_ims_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO IMS — Voice Signaling & RTP Media Performance",
        "uid": "mvno-ims-voice-media",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["mvno", "plane:ims", "voice", "rtpengine", "kamailio", "asterisk", "sota"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    
    # Media KPIs
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "🎙️ IMS VOICE SIGNALING & RTP MEDIA RELAY HEALTH", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 1, "title": "Active RTP Sessions", "description": "Active audio channels currently bridged through in-kernel RTPEngine.",
        "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 0, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "rtpengine_current_sessions default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 2, "title": "Stuck RTP Streams", "description": "RTP streams with 0 packets transmitted (dead audio / firewall drop).",
        "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 4, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_zeropacket_sessions) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 3, "title": "RTP Packet Errors", "description": "Corrupted or dropped media packets.",
        "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 8, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF9100", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF9100", "value": 1}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_packet_errors_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 4, "title": "Available Media Ports", "description": "Free UDP ports in the 10000-20000 RTP port allocation pool.",
        "type": "stat", "gridPos": {"h": 4, "w": 4, "x": 12, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "rtpengine_ports_free default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 5, "title": "Total Processed Calls", "description": "Cumulative SIP calls handled since startup.",
        "type": "stat", "gridPos": {"h": 4, "w": 8, "x": 16, "y": 1},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#38BDF8", "mode": "fixed"}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_call_requests_total) default 0", "refId": "A"}]
    })

    # Time Series Throughput
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "📈 MEDIA PLANE BANDWIDTH & PACKET VELOCITY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "🌊 Real-Time RTP Media Stream Bandwidth (Bytes/s)", "description": "Real-time G.711u / Opus audio stream throughput bridged through RTPEngine.",
        "type": "timeseries", "gridPos": {"h": 7, "w": 12, "x": 0, "y": 6},
        "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 15, "lineWidth": 2}, "unit": "Bps"}},
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "rate(rtpengine_bytes_total[$__rate_interval]) default 0", "legendFormat": "Bandwidth", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 7, "title": "📊 SIP Signaling Call Rate (INVITEs / s)", "description": "Velocity of SIP call setup and teardown transactions through Kamailio core.",
        "type": "timeseries", "gridPos": {"h": 7, "w": 12, "x": 12, "y": 6},
        "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 15, "lineWidth": 2}, "unit": "reqps"}},
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "rate(mvno_call_requests_total[$__rate_interval]) default 0", "legendFormat": "Call Rate", "refId": "A"}]
    })

    return dash

# Generate and write all dashboards
dashboards = [
    ("mvno_soc_antifraud.json", make_soc_dashboard()),
    ("mvno_5g_core_dpi.json", make_5g_dashboard()),
    ("mvno_ims_voice_media.json", make_ims_dashboard())
]

for filename, dash in dashboards:
    path = os.path.join(DASH_DIR, filename)
    with open(path, "w") as f:
        json.dump(dash, f, indent=2)
    print(f"Generated {filename} at {path}")

print("Tier-1 Carrier NOC Suite generation complete!")
