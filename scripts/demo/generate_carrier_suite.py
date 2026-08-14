#!/usr/bin/env python3
"""
generate_carrier_suite.py — Generates the Complete SOTA Tier-1 Vibrant Telecom NOC Suite
Using 100% Real, Authoritative Metric Names from Live Exporters:
  - RTPEngine: rtpengine_sessions, rtpengine_bytes_total, rtpengine_zero_packet_streams_total, rtpengine_packet_errors_total, rtpengine_ports_free, rtpengine_uptime_seconds
  - IP-SM-GW: mvno_bridge_sms_2g_to_5g_total, mvno_bridge_sms_5g_to_2g_total, mvno_bridge_sms_failures_total, mvno_bridge_sms_attempts_total
  - Vosk ASR: mvno_vosk_transcriptions_total, mvno_vosk_classified_total, mvno_vosk_scamflag_total, mvno_vosk_model_ready
  - Telecom EIR: mvno_eir_sim_swap_detected_total, mvno_eir_cache_size, mvno_smishing_url_blocked_total
  - 5G SA Core & DPI: ran_ue, fivegs_upffunction_upf_sessionnbr, mvno_dpi_bytes_total, mvno_dpi_flows_active, mvno_dpi_threats_intercepted_total
"""
import json
import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
DASH_DIR = os.path.join(REPO_ROOT, "configs/grafana/provisioning/dashboards")
os.makedirs(DASH_DIR, exist_ok=True)

DS_VM = {"type": "prometheus", "uid": "victoriametrics"}
DS_VL = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}

# ──────────────────────────────────────────────────────────────────────────────
# 1. MASTER UNIFIED DASHBOARD: MVNO NOC — Unified
# ──────────────────────────────────────────────────────────────────────────────
def make_unified_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO NOC — Unified",
        "uid": "mvno-unified-noc",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["carrier-grade", "component:unified", "mvno", "noc", "plane:core", "sota", "vibrant"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    
    # ─── SECTION 1: HERO OVERVIEW (y=0) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "title": "⚡ CARRIER OPERATIONS CENTER (NOC) — HIGH-DENSITY HERO KPI OVERVIEW", "type": "row"})
    
    hero_stats = [
        ("📱 Total SMS Processed", "sum(mvno_sms_requests_total) default 0", "#00F2FE", "Total incoming SMS messages ingested and analyzed through the core network.", "short", 0),
        ("🎙️ Total Voice Calls", "sum(mvno_call_requests_total) default 0", "#00E676", "Total SIP voice calls initiated and handled across Kamailio and RTPEngine.", "short", 4),
        ("🛡️ Threats Blocked", "sum(mvno_sms_blocked_total) + sum(mvno_call_blocked_total) default 0", "#FF0055", "Malicious smishing URLs, spam text, and fraudulent voice calls blocked by the AI Gateway.", "short", 8),
        ("📡 5G SA Active UEs", "ran_ue default 0", "#7928CA", "Active 5G Standalone User Equipments registered to AMF over NGAP 38412.", "short", 12),
        ("🚨 5G L7 DPI Intercepts", "sum(mvno_dpi_threats_intercepted_total) default 0", "#FF5252", "Malicious DNS domain names and HTTP hostnames intercepted live on 5G data plane.", "short", 16),
        ("⏱️ Media Relay Uptime", "rtpengine_uptime_seconds default 0", "#38BDF8", "Continuous uptime of the high-throughput in-kernel RTPEngine media relay.", "s", 20)
    ]
    
    for idx, (title, expr, color, desc, unit, x_pos) in enumerate(hero_stats, 1):
        dash["panels"].append({
            "datasource": DS_VM, "id": idx, "title": title, "description": desc, "type": "stat",
            "gridPos": {"h": 4, "w": 4, "x": x_pos, "y": 1},
            "fieldConfig": {"defaults": {"color": {"fixedColor": color, "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": None}]}, "unit": unit}},
            "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
            "targets": [{"datasource": DS_VM, "expr": expr, "refId": "A"}]
        })

    # ─── SECTION 2: TOPOLOGY & ARCHITECTURE (y=5) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 105, "title": "🌐 END-TO-END TELECOM TOPOLOGY & DATA FLOW PIPELINE", "type": "row"})
    
    topology_html = """<div style="display:flex; flex-direction:column; gap:10px; padding:12px; background:rgba(15,23,42,0.75); border-radius:12px; border:1px solid rgba(255,255,255,0.12);">
  <div style="font-size:11px; font-weight:bold; color:#00F2FE; text-transform:uppercase; letter-spacing:0.8px;">📞 Voice Signaling & Media Path (SIP RFC 3261 + In-Kernel RTP Relay)</div>
  <div style="display:flex; align-items:center; justify-content:space-between; gap:6px;">
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(0,242,254,0.18), rgba(0,242,254,0.05)); border:1px solid #00F2FE; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">📱</div><div style="font-weight:bold; color:#00F2FE; font-size:11px;">Caller UE</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">15553332211</div>
    </div>
    <div style="color:#00F2FE; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(121,40,202,0.18), rgba(121,40,202,0.05)); border:1px solid #7928CA; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">📡</div><div style="font-weight:bold; color:#7928CA; font-size:11px;">Kamailio Core</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">5060/UDP (407 Auth)</div>
    </div>
    <div style="color:#7928CA; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(255,145,0,0.18), rgba(255,145,0,0.05)); border:1px solid #FF9100; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">🛡️</div><div style="font-weight:bold; color:#FF9100; font-size:11px;">Telecom Gateway</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">Java 21 / OCS / EIR</div>
    </div>
    <div style="color:#FF9100; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(0,230,118,0.18), rgba(0,230,118,0.05)); border:1px solid #00E676; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">🎙️</div><div style="font-weight:bold; color:#00E676; font-size:11px;">RTPEngine Relay</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">10000-20000/UDP</div>
    </div>
    <div style="color:#00E676; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(0,242,254,0.18), rgba(0,242,254,0.05)); border:1px solid #00F2FE; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">📲</div><div style="font-weight:bold; color:#00F2FE; font-size:11px;">Callee Handset</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">15551234567 / 9998888</div>
    </div>
  </div>

  <div style="font-size:11px; font-weight:bold; color:#7928CA; text-transform:uppercase; letter-spacing:0.8px;">📡 5G Standalone Data Plane & Deep Packet Inspection (GTP-U TS 29.281)</div>
  <div style="display:flex; align-items:center; justify-content:space-between; gap:6px;">
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(121,40,202,0.18), rgba(121,40,202,0.05)); border:1px solid #7928CA; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">📶</div><div style="font-weight:bold; color:#7928CA; font-size:11px;">5G UE (UERANSIM)</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">10.45.0.5 (uesimtun0)</div>
    </div>
    <div style="color:#7928CA; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(56,189,248,0.18), rgba(56,189,248,0.05)); border:1px solid #38BDF8; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">🗼</div><div style="font-weight:bold; color:#38BDF8; font-size:11px;">5G gNodeB</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">NGAP 38412 / GTP-U</div>
    </div>
    <div style="color:#38BDF8; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(255,0,85,0.18), rgba(255,0,85,0.05)); border:1px solid #FF0055; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">⚙️</div><div style="font-weight:bold; color:#FF0055; font-size:11px;">Open5GS UPF</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">10.45.0.1 (ogstun)</div>
    </div>
    <div style="color:#FF0055; font-weight:bold; font-size:14px;">➔</div>
    <div style="flex:1; padding:8px; background:linear-gradient(135deg, rgba(0,230,118,0.18), rgba(0,230,118,0.05)); border:1px solid #00E676; border-radius:8px; text-align:center;">
      <div style="font-size:16px;">🔍</div><div style="font-weight:bold; color:#00E676; font-size:11px;">5G L7 DPI Probe</div><div style="font-size:9px; color:rgba(255,255,255,0.7);">DNS / TLS SNI / HTTP</div>
    </div>
  </div>
</div>"""

    dash["panels"].append({
        "gridPos": {"h": 8, "w": 18, "x": 0, "y": 6}, "id": 106,
        "options": {"content": topology_html, "mode": "html"}, "title": "🗺️ Live Carrier Network Architecture Topology", "type": "text"
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 118, "title": "📊 Total 5G Inspected Payload", "description": "Cumulative user-plane payload decapsulated and inspected on ogstun.", "type": "stat",
        "gridPos": {"h": 8, "w": 6, "x": 18, "y": 6},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]}, "unit": "decbytes"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_dpi_bytes_total) default 0", "refId": "A"}]
    })

    # ─── SECTION 3: SOC & AI ANTI-FRAUD MESH (y=14) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14}, "id": 200, "title": "🛡️ AI ANTI-FRAUD & CYBER SECURITY MESH", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 201, "title": "⚡ Offline Vosk ASR Speech Transcriptions", "description": "Audio call media segments transcribed and classified by Vosk JNI.", "type": "stat",
        "gridPos": {"h": 7, "w": 12, "x": 0, "y": 15},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_vosk_transcriptions_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 202, "title": "📱 SMS Ingestion vs Spam Neutralization Volume", "description": "Incoming SMS messages versus spam/smishing blocked by AI.", "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 12, "y": 15},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "short"},
            "overrides": [
                {"matcher": {"id": "byName", "options": "Ingested SMS"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "Blocked Spam"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF0055", "mode": "fixed"}}]}
            ]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [
            {"datasource": DS_VM, "expr": "sum(mvno_sms_requests_total) default 0", "legendFormat": "Ingested SMS", "refId": "A"},
            {"datasource": DS_VM, "expr": "sum(mvno_sms_blocked_total) default 0", "legendFormat": "Blocked Spam", "refId": "B"}
        ]
    })

    # ─── SECTION 4: 5G SA CORE & L7 DPI (y=22) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 22}, "id": 116, "title": "📡 5G SA CORE & USER-PLANE L7 DEEP PACKET INSPECTION (DPI)", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 119, "title": "Active 5G Data Plane Flows by Protocol", "description": "Live packet flows (DNS, TLS, HTTP, RTP) tracked across 5G sessions.", "type": "stat",
        "gridPos": {"h": 6, "w": 10, "x": 0, "y": 23},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "mvno_dpi_flows_active", "legendFormat": "{{protocol}}", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 120, "title": "📈 5G UPF L7 User-Plane Traffic by Protocol", "description": "Decapsulated user-plane bandwidth across active 5G slices.", "type": "timeseries",
        "gridPos": {"h": 6, "w": 14, "x": 10, "y": 23},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "decbytes"},
            "overrides": [
                {"matcher": {"id": "byName", "options": "dns"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "tls"}, "properties": [{"id": "color", "value": {"fixedColor": "#7928CA", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "http"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF9100", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "rtp"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]}
            ]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "sum by (protocol) (mvno_dpi_bytes_total)", "legendFormat": "{{protocol}}", "refId": "A"}]
    })

    # ─── SECTION 5: IMS VOICE & RTP MEDIA (y=29) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 29}, "id": 104, "title": "🎙️ IMS VOICE SIGNALING & RTP MEDIA RELAY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 108, "title": "🎙️ Voice Call Signaling & Interception Volume", "description": "SIP call attempts routed through Kamailio versus fraud calls blocked.", "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 0, "y": 30},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "short"},
            "overrides": [
                {"matcher": {"id": "byName", "options": "Processed Calls"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "Blocked Fraud"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF0055", "mode": "fixed"}}]}
            ]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [
            {"datasource": DS_VM, "expr": "sum(mvno_call_requests_total) default 0", "legendFormat": "Processed Calls", "refId": "A"},
            {"datasource": DS_VM, "expr": "sum(mvno_call_blocked_total) default 0", "legendFormat": "Blocked Fraud", "refId": "B"}
        ]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 19, "title": "🌊 Real-Time RTP Media Stream Bandwidth", "description": "Real-time G.711u / Opus audio stream bandwidth bridged through RTPEngine.", "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 12, "y": 30},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "Bps"},
            "overrides": [{"matcher": {"id": "byName", "options": "Media Bandwidth"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]}]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "rate(rtpengine_bytes_total[$__rate_interval]) default 0", "legendFormat": "Media Bandwidth", "refId": "A"}]
    })

    # ─── SECTION 6: IP-SM-GW 2G↔5G SMS INTERWORKING (y=37) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 37}, "id": 107, "title": "🌉 IP-SM-GW 2G↔5G SMS INTERWORKING & PROTOCOL BRIDGING", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 110, "title": "2G ➔ 5G Relay", "description": "GSM SMPP SMS bridged to 5G IMS core.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 0, "y": 38},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_bridge_sms_2g_to_5g_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 111, "title": "5G ➔ 2G Backhaul", "description": "SIP MESSAGE SMS delivered to GSM handsets.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 4, "y": 38},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#7928CA", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#7928CA", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_bridge_sms_5g_to_2g_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 112, "title": "Bridge Failures", "description": "Timed-out or dropped cross-network SMS.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 8, "y": 38},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_bridge_sms_failures_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 113, "title": "Bridge Ingress Attempts", "description": "Cross-network SMS bridge attempts initiated.", "type": "stat",
        "gridPos": {"h": 4, "w": 12, "x": 12, "y": 38},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#38BDF8", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#38BDF8", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_bridge_sms_attempts_total) default 0", "refId": "A"}]
    })

    # ─── SECTION 7: MEDIA & CORE INFRASTRUCTURE HEALTH (y=42) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 42}, "id": 121, "title": "⚡ INFRASTRUCTURE & MEDIA PLANE HEALTH", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 122, "title": "Active RTP Sessions", "description": "Active audio channels in RTPEngine.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 0, "y": 43},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "rtpengine_sessions default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 123, "title": "Stuck RTP Streams", "description": "Zero-packet stuck audio sessions.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 4, "y": 43},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_zero_packet_streams_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 124, "title": "RTP Packet Errors", "description": "Corrupted/dropped UDP media packets.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 8, "y": 43},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF9100", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF9100", "value": 1}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_packet_errors_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 125, "title": "Available Ports", "description": "Free ports in 10000-20000 pool.", "type": "stat",
        "gridPos": {"h": 4, "w": 4, "x": 12, "y": 43},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "rtpengine_ports_free default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 126, "title": "🟢 Live Core Health (up=1)", "description": "Prometheus health check targets answering (10/10 expected).", "type": "stat",
        "gridPos": {"h": 4, "w": 8, "x": 16, "y": 43},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#38BDF8", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#38BDF8", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(up)", "refId": "A"}]
    })

    # ─── SECTION 8: VICTORIALOGS INTERCEPTION STREAM (y=47) ───
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 47}, "id": 114, "title": "📋 CARRIER INTERCEPTION & SECURITY AUDIT LOGS (VICTORIALOGS)", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VL, "id": 115, "title": "🔍 Real-Time Carrier Interception Stream", "description": "Live audit logs for blocked SMS, robocall intercepts, and GTP-U alerts.", "type": "logs",
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": 48},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00F2FE", "mode": "fixed"}}},
        "options": {"dedupStrategy": "none", "enableLogDetails": True, "showLabels": True, "showTime": True, "sortOrder": "Descending", "wrapLogMessage": True},
        "targets": [{"datasource": DS_VL, "expr": "* | \"SMS BLOCKED BY MVNO INTERCEPTION\" or \"BLOCKED\" or \"DPI-ALERT\"", "refId": "A"}]
    })

    return dash

# ──────────────────────────────────────────────────────────────────────────────
# 2. SPECIALIZED SOC DASHBOARD: MVNO SOC — AI Anti-Fraud & Cyber Security Mesh
# ──────────────────────────────────────────────────────────────────────────────
def make_soc_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO SOC — AI Anti-Fraud & Cyber Security Mesh",
        "uid": "mvno-soc-antifraud",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["anti-fraud", "dsp", "mvno", "plane:soc", "security", "sota", "stir-shaken", "vibrant"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "🛡️ SECURITY OPERATIONS CENTER (SOC) — THREAT INTELLIGENCE SUMMARY", "type": "row"})
    
    soc_kpis = [
        ("🚨 Malicious SMS / Smishing Blocked", "sum(mvno_sms_blocked_total) default 0", "#FF0055", "Smishing messages containing weaponized URLs or financial scams intercepted by AI.", 0),
        ("📞 Fraudulent Voice Calls Blocked", "sum(mvno_call_blocked_total) default 0", "#FF5252", "Robocalls, spoofed caller IDs, and fraud voice attempts blocked at Kamailio.", 6),
        ("🔍 5G UPF Phishing Intercepts", "sum(mvno_dpi_threats_intercepted_total) default 0", "#FF9100", "L7 DNS queries and TLS SNIs blocked on 5G user plane (ogstun 10.45.0.1).", 12),
        ("🔐 EIR SIM-Swap Violations", "sum(mvno_eir_sim_swap_detected_total) default 0", "#7928CA", "IMSI/IMEI binding mismatches flagged by Equipment Identity Register.", 18)
    ]
    for idx, (title, expr, color, desc, x_pos) in enumerate(soc_kpis, 1):
        dash["panels"].append({
            "datasource": DS_VM, "id": idx, "title": title, "description": desc, "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": x_pos, "y": 1},
            "fieldConfig": {"defaults": {"color": {"fixedColor": color, "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": None}]}, "unit": "short"}},
            "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
            "targets": [{"datasource": DS_VM, "expr": expr, "refId": "A"}]
        })

    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "🧠 AI ACOUSTIC SPEECH & VOICE CLONE DETECTION PIPELINE", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 5, "title": "⚡ Offline Vosk ASR Speech Transcriptions", "description": "Audio call media segments transcribed and classified by Vosk JNI.", "type": "stat",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 6},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_vosk_transcriptions_total) default 0", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "🛡️ Smishing URLs Neutralized by Sandbox", "description": "Malicious URLs redirected through SSRF guard and blocked.", "type": "stat",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 6},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": "#FF0055", "value": None}]}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "sum(mvno_smishing_url_blocked_total) default 0", "refId": "A"}]
    })

    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14}, "id": 30, "title": "📋 REAL-TIME THREAT INTERCEPTION STREAM (VICTORIALOGS)", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VL, "id": 7, "title": "🔍 Live Security & Fraud Neutralization Events", "description": "Structured log stream of blocked SMS, fraud robocalls, and 5G DPI alerts.", "type": "logs",
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": 15},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#FF0055", "mode": "fixed"}}},
        "options": {"dedupStrategy": "none", "enableLogDetails": True, "showLabels": True, "showTime": True, "sortOrder": "Descending", "wrapLogMessage": True},
        "targets": [{"datasource": DS_VL, "expr": "* | \"BLOCKED\" or \"FRAUD\" or \"DPI-ALERT\"", "refId": "A"}]
    })
    return dash

# ──────────────────────────────────────────────────────────────────────────────
# 3. SPECIALIZED 5G DASHBOARD: MVNO 5G SA — Core Network & Data Plane Slicing
# ──────────────────────────────────────────────────────────────────────────────
def make_5g_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO 5G SA — Core Network & Data Plane Slicing",
        "uid": "mvno-5g-core-dpi",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["dpi", "gtp-u", "mvno", "open5gs", "plane:5g", "sota", "ueransim", "vibrant"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "📡 5G STANDALONE (SA) CORE STATUS & RADIO METRICS", "type": "row"})
    
    fiveg_kpis = [
        ("📱 Registered 5G UEs", "ran_ue default 0", "#7928CA", "Active 5G User Equipments registered to AMF over NGAP 38412.", "short", 0),
        ("📶 Active 5G PDU Sessions (UPF)", "fivegs_upffunction_upf_sessionnbr default 0", "#00F2FE", "Active GTP-U PDU user-plane sessions on Open5GS UPF (ogstun 10.45.0.1).", "short", 6),
        ("🔍 5G L7 Inspected Payload", "sum(mvno_dpi_bytes_total) default 0", "#00E676", "Total user-plane payload decapsulated from GTP-U tunnels.", "decbytes", 12),
        ("⚡ 5G Core Functions (AMF/SMF/UPF)", "count(up{job=~\"open5gs-.*|5g-.*\"}) default 0", "#38BDF8", "Prometheus liveness of 5G SA Network Functions.", "short", 18)
    ]
    for idx, (title, expr, color, desc, unit, x_pos) in enumerate(fiveg_kpis, 1):
        dash["panels"].append({
            "datasource": DS_VM, "id": idx, "title": title, "description": desc, "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": x_pos, "y": 1},
            "fieldConfig": {"defaults": {"color": {"fixedColor": color, "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": None}]}, "unit": unit}},
            "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
            "targets": [{"datasource": DS_VM, "expr": expr, "refId": "A"}]
        })

    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "📈 5G USER-PLANE DEEP PACKET INSPECTION & PROTOCOL VELOCITY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 5, "title": "📊 5G Application Flow Distribution (DNS / TLS / HTTP / RTP)", "description": "Current active packet flows tracked by protocol on ogstun.", "type": "stat",
        "gridPos": {"h": 6, "w": 10, "x": 0, "y": 6},
        "fieldConfig": {"defaults": {"color": {"fixedColor": "#00E676", "mode": "fixed"}, "unit": "short"}},
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
        "targets": [{"datasource": DS_VM, "expr": "mvno_dpi_flows_active", "legendFormat": "{{protocol}}", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "🌊 5G Decapsulated L7 User-Plane Bandwidth by Protocol", "description": "Time-series throughput of user-plane protocols decapsulated from GTP-U.", "type": "timeseries",
        "gridPos": {"h": 6, "w": 14, "x": 10, "y": 6},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "decbytes"},
            "overrides": [
                {"matcher": {"id": "byName", "options": "dns"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "tls"}, "properties": [{"id": "color", "value": {"fixedColor": "#7928CA", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "http"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF9100", "mode": "fixed"}}]},
                {"matcher": {"id": "byName", "options": "rtp"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]}
            ]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "sum by (protocol) (mvno_dpi_bytes_total)", "legendFormat": "{{protocol}}", "refId": "A"}]
    })
    return dash

# ──────────────────────────────────────────────────────────────────────────────
# 4. SPECIALIZED IMS DASHBOARD: MVNO IMS — Voice Signaling & RTP Media Performance
# ──────────────────────────────────────────────────────────────────────────────
def make_ims_dashboard():
    dash = {
        "__inputs": [], "__requires": [],
        "title": "MVNO IMS — Voice Signaling & RTP Media Performance",
        "uid": "mvno-ims-voice-media",
        "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "liveNow": True, "refresh": "5s", "schemaVersion": 39,
        "tags": ["asterisk", "kamailio", "mvno", "plane:ims", "rtpengine", "sota", "voice", "vibrant"],
        "time": {"from": "now-15m", "to": "now"},
        "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
        "timezone": "browser",
        "panels": []
    }
    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 10, "title": "🎙️ IMS VOICE SIGNALING & RTP MEDIA RELAY HEALTH", "type": "row"})
    
    ims_kpis = [
        ("Active RTP Sessions", "rtpengine_sessions default 0", "#00F2FE", "Active audio channels currently bridged through in-kernel RTPEngine.", 0),
        ("Stuck RTP Streams", "sum(rtpengine_zero_packet_streams_total) default 0", "#FF0055", "RTP streams with 0 packets transmitted (dead audio / firewall drop).", 4),
        ("RTP Packet Errors", "sum(rtpengine_packet_errors_total) default 0", "#FF9100", "Corrupted or dropped media packets.", 8),
        ("Available Media Ports", "rtpengine_ports_free default 0", "#00E676", "Free UDP ports in the 10000-20000 RTP port allocation pool.", 12),
        ("Total Processed Calls", "sum(mvno_call_requests_total) default 0", "#38BDF8", "Cumulative SIP calls handled since startup.", 16)
    ]
    for idx, (title, expr, color, desc, x_pos) in enumerate(ims_kpis, 1):
        w = 8 if idx == 5 else 4
        dash["panels"].append({
            "datasource": DS_VM, "id": idx, "title": title, "description": desc, "type": "stat",
            "gridPos": {"h": 4, "w": w, "x": x_pos, "y": 1},
            "fieldConfig": {"defaults": {"color": {"fixedColor": color, "mode": "fixed"}, "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": None}]}, "unit": "short"}},
            "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
            "targets": [{"datasource": DS_VM, "expr": expr, "refId": "A"}]
        })

    dash["panels"].append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 20, "title": "📈 MEDIA PLANE BANDWIDTH & PACKET VELOCITY", "type": "row"})
    dash["panels"].append({
        "datasource": DS_VM, "id": 6, "title": "🌊 Real-Time RTP Media Stream Bandwidth (Bytes/s)", "description": "Real-time G.711u / Opus audio stream throughput bridged through RTPEngine.", "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 0, "y": 6},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "Bps"},
            "overrides": [{"matcher": {"id": "byName", "options": "Bandwidth"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]}]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "rate(rtpengine_bytes_total[$__rate_interval]) default 0", "legendFormat": "Bandwidth", "refId": "A"}]
    })
    dash["panels"].append({
        "datasource": DS_VM, "id": 7, "title": "📊 SIP Signaling Call Rate (INVITEs / s)", "description": "Velocity of SIP call setup and teardown transactions through Kamailio core.", "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 12, "y": 6},
        "fieldConfig": {
            "defaults": {"color": {"mode": "palette-classic"}, "custom": {"fillOpacity": 18, "lineWidth": 2}, "unit": "reqps"},
            "overrides": [{"matcher": {"id": "byName", "options": "Call Rate"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]}]
        },
        "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": DS_VM, "expr": "rate(mvno_call_requests_total[$__rate_interval]) default 0", "legendFormat": "Call Rate", "refId": "A"}]
    })
    return dash

# ──────────────────────────────────────────────────────────────────────────────
# WRITE AND PUBLISH ALL 4 DASHBOARDS
# ──────────────────────────────────────────────────────────────────────────────
all_dashboards = [
    ("mvno_unified_noc.json", make_unified_dashboard()),
    ("mvno_soc_antifraud.json", make_soc_dashboard()),
    ("mvno_5g_core_dpi.json", make_5g_dashboard()),
    ("mvno_ims_voice_media.json", make_ims_dashboard())
]

for filename, dash_obj in all_dashboards:
    filepath = os.path.join(DASH_DIR, filename)
    with open(filepath, "w") as f:
        json.dump(dash_obj, f, indent=2)
    print(f"✓ Wrote {filename} ({len(dash_obj['panels'])} panels)")

print("\nAll 4 Carrier NOC Dashboards generated with 100% authoritative exporter metric names!")
