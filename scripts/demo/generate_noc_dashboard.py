#!/usr/bin/env python3
"""
generate_noc_dashboard.py — Generates SOTA Carrier NOC Dashboard with Clean Non-Overlapping Grid
"""
import json
import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OUTPUT_FILE = os.path.join(REPO_ROOT, "configs/grafana/provisioning/dashboards/mvno_unified_noc.json")

DS_VM = {"type": "prometheus", "uid": "victoriametrics"}
DS_VL = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}

dashboard = {
    "__inputs": [],
    "__requires": [],
    "title": "MVNO NOC — Unified",
    "uid": "mvno-unified-noc",
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,
    "liveNow": True,
    "refresh": "5s",
    "schemaVersion": 39,
    "tags": ["mvno", "plane:core", "component:unified", "noc", "sota", "carrier-grade"],
    "time": {"from": "now-15m", "to": "now"},
    "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m"]},
    "timezone": "browser",
    "panels": []
}

panels = []

# ─── ROW 1: HERO OVERVIEW (y=0) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
    "id": 100,
    "title": "⚡ CARRIER OPERATIONS CENTER (NOC) — HIGH-DENSITY HERO KPI OVERVIEW",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00F2FE"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 0, "y": 1},
    "id": 1,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_sms_requests_total) default 0", "refId": "A"}],
    "title": "📱 Total SMS Processed",
    "description": "Total incoming SMS messages ingested and analyzed through the MVNO core network.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00E676"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 4, "y": 1},
    "id": 2,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_call_requests_total) default 0", "refId": "A"}],
    "title": "🎙️ Total Voice Calls",
    "description": "Total SIP voice calls initiated and handled across Kamailio and RTPEngine.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#FF0055"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 8, "y": 1},
    "id": 4,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_sms_blocked_total) + sum(mvno_call_blocked_total) default 0", "refId": "A"}],
    "title": "🛡️ Threats Blocked (AI Filter)",
    "description": "Malicious smishing URLs, spam text, and fraudulent voice calls blocked by the AI Gateway.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#7928CA"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#7928CA", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 12, "y": 1},
    "id": 99,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "fivegs_upffunction_upf_sessionnbr default 0", "refId": "A"}],
    "title": "📡 5G SA Active Sessions",
    "description": "Active 5G Standalone PDU sessions registered on Open5GS UPF (ogstun).",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#FF5252"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF5252", "value": 1}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 16, "y": 1},
    "id": 117,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_dpi_threats_intercepted_total) default 0", "refId": "A"}],
    "title": "🚨 5G L7 Phishing Intercepts",
    "description": "Malicious DNS domain names and HTTP hostnames intercepted live on the 5G data plane.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#38BDF8"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#38BDF8", "value": None}]},
            "unit": "s"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 20, "y": 1},
    "id": 20,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "rtpengine_uptime_seconds default 0", "refId": "A"}],
    "title": "⏱️ RTPEngine Core Uptime",
    "description": "Continuous uptime of the high-throughput in-kernel RTPEngine media relay.",
    "type": "stat"
})

# ─── ROW 2: DATA FLOW TOPOLOGY (y=5) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
    "id": 105,
    "title": "🌐 END-TO-END TELECOM TOPOLOGY & DATA FLOW PIPELINE",
    "type": "row"
})

topology_html = """<div style="display:flex; flex-direction:column; gap:12px; padding:12px; background:rgba(15,23,42,0.7); border-radius:12px; border:1px solid rgba(255,255,255,0.12);">
  <!-- VOICE -->
  <div style="font-size:12px; font-weight:bold; color:#00F2FE; text-transform:uppercase; letter-spacing:0.5px;">📞 Voice Signaling & Media Path (SIP RFC 3261 + RTP Relay)</div>
  <div style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(0,242,254,0.15), rgba(0,242,254,0.05)); border:1px solid #00F2FE; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">📱</div><div style="font-weight:bold; color:#00F2FE; font-size:12px;">Caller UE</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">15553332211</div>
    </div>
    <div style="color:#00F2FE; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(121,40,202,0.15), rgba(121,40,202,0.05)); border:1px solid #7928CA; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">📡</div><div style="font-weight:bold; color:#7928CA; font-size:12px;">Kamailio SIP Proxy</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">5060/UDP (407 Auth)</div>
    </div>
    <div style="color:#7928CA; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(255,145,0,0.15), rgba(255,145,0,0.05)); border:1px solid #FF9100; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">🛡️</div><div style="font-weight:bold; color:#FF9100; font-size:12px;">Telecom Gateway</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">Java 21 / OCS / EIR</div>
    </div>
    <div style="color:#FF9100; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(0,230,118,0.15), rgba(0,230,118,0.05)); border:1px solid #00E676; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">🎙️</div><div style="font-weight:bold; color:#00E676; font-size:12px;">RTPEngine Relay</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">10000-20000/UDP</div>
    </div>
    <div style="color:#00E676; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(0,242,254,0.15), rgba(0,242,254,0.05)); border:1px solid #00F2FE; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">📲</div><div style="font-weight:bold; color:#00F2FE; font-size:12px;">Callee Handset</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">15551234567 / 9998888</div>
    </div>
  </div>

  <!-- 5G USER PLANE & DPI -->
  <div style="font-size:12px; font-weight:bold; color:#7928CA; text-transform:uppercase; letter-spacing:0.5px;">📡 5G Standalone Data Plane & Deep Packet Inspection (GTP-U TS 29.281)</div>
  <div style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(121,40,202,0.15), rgba(121,40,202,0.05)); border:1px solid #7928CA; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">📶</div><div style="font-weight:bold; color:#7928CA; font-size:12px;">5G UE (UERANSIM)</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">10.45.0.5 (uesimtun0)</div>
    </div>
    <div style="color:#7928CA; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(56,189,248,0.15), rgba(56,189,248,0.05)); border:1px solid #38BDF8; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">🗼</div><div style="font-weight:bold; color:#38BDF8; font-size:12px;">5G gNodeB</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">NGAP 38412 / GTP-U</div>
    </div>
    <div style="color:#38BDF8; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(255,0,85,0.15), rgba(255,0,85,0.05)); border:1px solid #FF0055; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">⚙️</div><div style="font-weight:bold; color:#FF0055; font-size:12px;">Open5GS UPF</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">10.45.0.1 (ogstun)</div>
    </div>
    <div style="color:#FF0055; font-weight:bold;">➔</div>
    <div style="flex:1; padding:10px; background:linear-gradient(135deg, rgba(0,230,118,0.15), rgba(0,230,118,0.05)); border:1px solid #00E676; border-radius:8px; text-align:center;">
      <div style="font-size:18px;">🔍</div><div style="font-weight:bold; color:#00E676; font-size:12px;">5G L7 DPI Probe</div><div style="font-size:10px; color:rgba(255,255,255,0.7);">DNS / TLS SNI / HTTP</div>
    </div>
  </div>
</div>"""

panels.append({
    "gridPos": {"h": 8, "w": 18, "x": 0, "y": 6},
    "id": 106,
    "options": {"content": topology_html, "mode": "html"},
    "title": "🗺️ Live Carrier Network Architecture Topology",
    "type": "text"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00F2FE"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]},
            "unit": "decbytes"
        }
    },
    "gridPos": {"h": 8, "w": 6, "x": 18, "y": 6},
    "id": 118,
    "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_dpi_bytes_total) default 0", "refId": "A"}],
    "title": "📊 Total 5G L7 Inspected Payload",
    "description": "Total user-plane payload bytes decapsulated and inspected on ogstun by the 5G DPI probe.",
    "type": "stat"
})

# ─── ROW 3: TRAFFIC & INTERCEPTION VELOCITY (y=14) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14},
    "id": 101,
    "title": "📡 CARRIER TRAFFIC & INTERCEPTION VELOCITY",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "short"
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": "Ingested SMS"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]},
            {"matcher": {"id": "byName", "options": "Blocked Spam"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF0055", "mode": "fixed"}}]}
        ]
    },
    "gridPos": {"h": 7, "w": 12, "x": 0, "y": 15},
    "id": 7,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [
        {"datasource": DS_VM, "expr": "sum(mvno_sms_requests_total) default 0", "legendFormat": "Ingested SMS", "refId": "A"},
        {"datasource": DS_VM, "expr": "sum(mvno_sms_blocked_total) default 0", "legendFormat": "Blocked Spam", "refId": "B"}
    ],
    "title": "📱 SMS Ingestion vs Spam Neutralization Volume",
    "description": "Real-time rate of incoming SMS messages versus scam/smishing messages blocked by the AI Gateway.",
    "type": "timeseries"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "short"
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": "Processed Calls"}, "properties": [{"id": "color", "value": {"fixedColor": "#00E676", "mode": "fixed"}}]},
            {"matcher": {"id": "byName", "options": "Blocked Fraud Calls"}, "properties": [{"id": "color", "value": {"fixedColor": "#FF0055", "mode": "fixed"}}]}
        ]
    },
    "gridPos": {"h": 7, "w": 12, "x": 12, "y": 15},
    "id": 8,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [
        {"datasource": DS_VM, "expr": "sum(mvno_call_requests_total) default 0", "legendFormat": "Processed Calls", "refId": "A"},
        {"datasource": DS_VM, "expr": "sum(mvno_call_blocked_total) default 0", "legendFormat": "Blocked Fraud Calls", "refId": "B"}
    ],
    "title": "🎙️ Voice Call Signaling & Interception Volume",
    "description": "Voice call signaling attempts routed through Kamailio SIP core and blocked robocalls.",
    "type": "timeseries"
})

# ─── ROW 4: 5G L7 DPI & ANTI-FRAUD MESH (y=22) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 22},
    "id": 116,
    "title": "🛡️ 5G CORE L7 DEEP PACKET INSPECTION (DPI) & ANTI-FRAUD SECURITY MESH",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00E676"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 6, "w": 10, "x": 0, "y": 23},
    "id": 119,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "mvno_dpi_flows_active", "legendFormat": "{{protocol}}", "refId": "A"}],
    "title": "📡 Active 5G Data Plane Flows by Protocol",
    "description": "Current active application flows (DNS, TLS, HTTP, RTP) tracked across 5G SA PDU sessions.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "decbytes"
        }
    },
    "gridPos": {"h": 6, "w": 14, "x": 10, "y": 23},
    "id": 120,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [{"datasource": DS_VM, "expr": "sum by (protocol) (mvno_dpi_bytes_total)", "legendFormat": "{{protocol}}", "refId": "A"}],
    "title": "📈 5G UPF L7 User-Plane Traffic by Protocol",
    "description": "Cumulative decapsulated data volume across DNS queries, TLS handshakes, and HTTP traffic.",
    "type": "timeseries"
})

# ─── ROW 5: SPEECH INTELLIGENCE & ASR (y=29) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 29},
    "id": 200,
    "title": "🤖 REAL-TIME VOSK ASR SPEECH RECOGNITION & PHONEME KEYWORD LATTICE",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF9100", "value": 2}, {"color": "#FF0055", "value": 5}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 7, "w": 12, "x": 0, "y": 30},
    "id": 201,
    "options": {"displayMode": "gradient", "minVizHeight": 10, "minVizWidth": 0, "orientation": "horizontal", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "showUnfilled": True},
    "targets": [{"datasource": DS_VM, "expr": "sum by (keyword) (mvno_speech_keyword_hits_total)", "legendFormat": "{{keyword}}", "refId": "A"}],
    "title": "🔑 Top Flagged Phishing & Fraud Keywords",
    "description": "Frequency of high-risk financial and phishing terms transcribed live from call media via Vosk JNI.",
    "type": "bargauge"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "short"
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": "Transcriptions Processed"}, "properties": [{"id": "color", "value": {"fixedColor": "#00F2FE", "mode": "fixed"}}]}
        ]
    },
    "gridPos": {"h": 7, "w": 12, "x": 12, "y": 30},
    "id": 202,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [{"datasource": DS_VM, "expr": "sum(mvno_speech_transcriptions_total) default 0", "legendFormat": "Transcriptions Processed", "refId": "A"}],
    "title": "⚡ Vosk ASR Speech Transcription Velocity",
    "description": "Number of audio call segments successfully decoded into text lattices by the offline Vosk engine.",
    "type": "timeseries"
})

# ─── ROW 6: IP-SM-GW & 2G↔5G SMS INTERWORKING (y=37) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 37},
    "id": 107,
    "title": "🌉 IP-SM-GW 2G↔5G SMS INTERWORKING & CHARGING LEDGER",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00F2FE"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 0, "y": 38},
    "id": 108,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(ipsmgw_messages_total{direction=\"2g_to_5g\"}) default 0", "refId": "A"}],
    "title": "2G ➔ 5G Relay",
    "description": "SMS messages received via Osmocom GSM SMSC and bridged into the 5G IMS core.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#7928CA"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#7928CA", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 4, "y": 38},
    "id": 109,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(ipsmgw_messages_total{direction=\"5g_to_2g\"}) default 0", "refId": "A"}],
    "title": "5G ➔ 2G Backhaul",
    "description": "SIP MESSAGE SMS from 5G softphones converted to SMPP and delivered to GSM handsets.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#FF0055"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 8, "y": 38},
    "id": 110,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(ipsmgw_delivery_failures_total) default 0", "refId": "A"}],
    "title": "Bridge Failures",
    "description": "Number of unroutable or timed-out cross-network SMS interworking deliveries.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 12, "x": 12, "y": 38},
    "id": 112,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [{"datasource": DS_VM, "expr": "sum by (direction) (ipsmgw_messages_total)", "legendFormat": "{{direction}}", "refId": "A"}],
    "title": "🌉 2G↔5G SMS Interworking Traffic",
    "description": "Cumulative volume of bidirectional SMS packets traversing the IP-SM-GW protocol converter.",
    "type": "timeseries"
})

# ─── ROW 7: MEDIA RELAY & RTPENGINE (y=42) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 42},
    "id": 104,
    "title": "⚡ RTPENGINE KERNEL MEDIA RELAY & INFRASTRUCTURE HEALTH",
    "type": "row"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00F2FE"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00F2FE", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 0, "y": 43},
    "id": 13,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "rtpengine_current_sessions default 0", "refId": "A"}],
    "title": "Active RTP Sessions",
    "description": "Active full-duplex RTP audio streams currently bridged by RTPEngine.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#FF0055"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF0055", "value": 1}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 4, "y": 43},
    "id": 113,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_zeropacket_sessions) default 0", "refId": "A"}],
    "title": "Stuck RTP Streams",
    "description": "RTP media sessions created but receiving 0 media packets (dead audio / NAT traversal failure).",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#FF9100"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}, {"color": "#FF9100", "value": 1}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 8, "y": 43},
    "id": 15,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(rtpengine_packet_errors_total) default 0", "refId": "A"}],
    "title": "RTP Packet Errors",
    "description": "Corrupted or out-of-order UDP media packets dropped by RTPEngine.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#00E676"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#00E676", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 4, "x": 12, "y": 43},
    "id": 16,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "rtpengine_ports_free default 0", "refId": "A"}],
    "title": "Available RTP Ports",
    "description": "Free UDP port allocations in the 10000-20000 media relay pool.",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "fixed", "fixedColor": "#38BDF8"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "#38BDF8", "value": None}]},
            "unit": "short"
        }
    },
    "gridPos": {"h": 4, "w": 8, "x": 16, "y": 43},
    "id": 11,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "auto"},
    "targets": [{"datasource": DS_VM, "expr": "sum(up)", "refId": "A"}],
    "title": "🟢 Live Infrastructure Health Targets (up=1)",
    "description": "Number of active telecom core services answering Prometheus health checks (10/10 expected).",
    "type": "stat"
})

panels.append({
    "datasource": DS_VM,
    "fieldConfig": {
        "defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {"axisCenteredZero": False, "fillOpacity": 15, "lineWidth": 2, "spanNulls": False},
            "unit": "Bps"
        }
    },
    "gridPos": {"h": 6, "w": 24, "x": 0, "y": 47},
    "id": 19,
    "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "none"}},
    "targets": [{"datasource": DS_VM, "expr": "rate(rtpengine_bytes_total[$__rate_interval]) default 0", "legendFormat": "Media Bandwidth (Bytes/s)", "refId": "A"}],
    "title": "📈 RTPEngine Real-Time Media Bandwidth Throughput",
    "description": "Real-time media plane bandwidth streamed across active voice and conference sessions.",
    "type": "timeseries"
})

# ─── ROW 8: VICTORIALOGS (y=53) ───
panels.append({
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 53},
    "id": 114,
    "title": "📋 CARRIER INTERCEPTION & SECURITY AUDIT LOGS (VICTORIALOGS)",
    "type": "row"
})

panels.append({
    "datasource": DS_VL,
    "fieldConfig": {
        "defaults": {
            "color": {"fixedColor": "#00F2FE", "mode": "fixed"},
            "custom": {"lineWidth": 1, "showLabels": True}
        }
    },
    "gridPos": {"h": 10, "w": 24, "x": 0, "y": 54},
    "id": 115,
    "options": {
        "dedupStrategy": "none",
        "enableLogDetails": True,
        "prettifyLogMessage": True,
        "showCommonLabels": False,
        "showLabels": True,
        "showTime": True,
        "sortOrder": "Descending",
        "wrapLogMessage": True
    },
    "targets": [{"datasource": DS_VL, "expr": "* | \"SMS BLOCKED BY MVNO INTERCEPTION\"", "refId": "A"}],
    "title": "🔍 Real-Time Interception Stream",
    "description": "Live log entries for carrier-intercepted messages, phishing threats, and subscriber state transitions.",
    "type": "logs"
})

dashboard["panels"] = panels

with open(OUTPUT_FILE, "w") as f:
    json.dump(dashboard, f, indent=2)

print(f"Generated clean, colorful, non-overlapping mvno_unified_noc.json with {len(panels)} panels at {OUTPUT_FILE}.")
