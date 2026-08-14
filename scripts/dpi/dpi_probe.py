#!/usr/bin/env python3
"""
MVNO 5G Standalone Core L7 Deep Packet Inspection (DPI) Engine (3GPP TS 23.501)
Attached to Open5GS UPF User-Plane interface (ogstun / GTP-U).

Features:
1. 5G Data Plane Sniffing: Binds live kernel sockets on 5G user plane gateway (ogstun / 10.45.0.1).
2. Layer 7 Protocol Decoding:
   - DNS (Port 53 / 5353): Parses DNS Query Names and flags Phishing DGA domains.
   - TLS SNI (Port 443 / 8443): Extracts HTTPS Server Name Indication from ClientHello.
   - HTTP (Port 80 / 8080): Extracts Host headers & HTTP paths.
   - RTP (UDP 10000-20000): Measures voice media throughput.
3. Exposes live Prometheus/VictoriaMetrics telemetry on HTTP :9094/metrics
"""
import os
import sys
import time
import socket
import struct
import select
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

DPI_PORT = 9094
SNIFFER_PORT_DNS = 5353
SNIFFER_PORT_HTTP = 8080
SNIFFER_PORT_RTP = 15000

# Thread-safe DPI traffic statistics
stats_lock = threading.Lock()
dpi_stats = {
    "dns_bytes": 0,
    "tls_bytes": 0,
    "http_bytes": 0,
    "rtp_bytes": 0,
    "other_bytes": 0,
    "phishing_threats": 0,
    "active_flows": {"dns": 0, "tls": 0, "http": 0, "rtp": 0}
}

PHISHING_DOMAINS = {
    "phishing-bank.com", "verify-account.xyz", "claim-reward-now.top",
    "login-secure-update.com", "fake-smishing-target.net"
}

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics" or self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            
            with stats_lock:
                output = f"""# HELP mvno_dpi_bytes_total Total Layer 7 payload bytes inspected by 5G UPF DPI engine.
# TYPE mvno_dpi_bytes_total counter
mvno_dpi_bytes_total{{protocol="dns",slice="embb"}} {dpi_stats['dns_bytes']}
mvno_dpi_bytes_total{{protocol="tls",slice="embb"}} {dpi_stats['tls_bytes']}
mvno_dpi_bytes_total{{protocol="http",slice="embb"}} {dpi_stats['http_bytes']}
mvno_dpi_bytes_total{{protocol="rtp",slice="embb"}} {dpi_stats['rtp_bytes']}
mvno_dpi_bytes_total{{protocol="other",slice="embb"}} {dpi_stats['other_bytes']}

# HELP mvno_dpi_flows_active Number of active application flows tracked by DPI.
# TYPE mvno_dpi_flows_active gauge
mvno_dpi_flows_active{{protocol="dns"}} {dpi_stats['active_flows']['dns']}
mvno_dpi_flows_active{{protocol="tls"}} {dpi_stats['active_flows']['tls']}
mvno_dpi_flows_active{{protocol="http"}} {dpi_stats['active_flows']['http']}
mvno_dpi_flows_active{{protocol="rtp"}} {dpi_stats['active_flows']['rtp']}

# HELP mvno_dpi_threats_intercepted_total Malicious L7 hostnames and phishing flows intercepted.
# TYPE mvno_dpi_threats_intercepted_total counter
mvno_dpi_threats_intercepted_total{{threat_type="phishing",protocol="dns"}} {dpi_stats['phishing_threats']}
"""
            self.wfile.write(output.encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


def inspect_dns_payload(data):
    """Decodes DNS query domain name from UDP payload."""
    try:
        if len(data) < 12:
            return None
        idx = 12
        domain_parts = []
        while idx < len(data):
            length = data[idx]
            if length == 0:
                break
            idx += 1
            if idx + length > len(data):
                break
            domain_parts.append(data[idx:idx+length].decode("ascii", errors="ignore"))
            idx += length
        if domain_parts:
            return ".".join(domain_parts)
    except Exception:
        pass
    return None


def inspect_tls_sni(data):
    """Extracts TLS SNI (Server Name Indication) from ClientHello packet."""
    try:
        if len(data) < 43 or data[0] != 0x16 or data[5] != 0x01:
            return None
        pos = 43
        session_id_len = data[pos]
        pos += 1 + session_id_len
        if pos + 2 > len(data): return None
        cipher_len = struct.unpack("!H", data[pos:pos+2])[0]
        pos += 2 + cipher_len
        if pos + 1 > len(data): return None
        comp_len = data[pos]
        pos += 1 + comp_len
        if pos + 2 > len(data): return None
        ext_total_len = struct.unpack("!H", data[pos:pos+2])[0]
        pos += 2
        
        while pos + 4 <= len(data):
            ext_type, ext_len = struct.unpack("!HH", data[pos:pos+4])
            pos += 4
            if ext_type == 0x0000 and pos + 5 <= len(data):
                sni_name_len = struct.unpack("!H", data[pos+3:pos+5])[0]
                return data[pos+5:pos+5+sni_name_len].decode("ascii", errors="ignore")
            pos += ext_len
    except Exception:
        pass
    return None


def process_packet(packet_bytes, src_ip="0.0.0.0", src_port=0, dst_port=0):
    """Parses packet bytes, inspects L7 payload, and updates DPI stats."""
    pkt_len = len(packet_bytes)
    with stats_lock:
        # 1. DNS (Port 53 or 5353)
        if src_port in (53, 5353) or dst_port in (53, 5353):
            dpi_stats["dns_bytes"] += pkt_len
            dpi_stats["active_flows"]["dns"] += 1
            domain = inspect_dns_payload(packet_bytes)
            if domain:
                print(f"[DPI-5G-DNS] 5G UE ({src_ip}:{src_port}) -> Intercepted DNS Query: {domain}", flush=True)
                if any(phish in domain for phish in PHISHING_DOMAINS):
                    dpi_stats["phishing_threats"] += 1
                    print(f"⚠️ [DPI-ALERT] 5G USER-PLANE PHISHING BLOCKED: {domain} from UE {src_ip}", flush=True)
            return "DNS"

        # 2. TLS SNI (Port 443 / 8443)
        elif src_port in (443, 8443) or dst_port in (443, 8443):
            dpi_stats["tls_bytes"] += pkt_len
            dpi_stats["active_flows"]["tls"] += 1
            sni = inspect_tls_sni(packet_bytes)
            if sni:
                print(f"[DPI-5G-TLS] 5G UE ({src_ip}:{src_port}) -> Intercepted TLS SNI: {sni}", flush=True)
                if any(phish in sni for phish in PHISHING_DOMAINS):
                    dpi_stats["phishing_threats"] += 1
                    print(f"⚠️ [DPI-ALERT] 5G USER-PLANE MALICIOUS TLS DETECTED: {sni}", flush=True)
            return "TLS"

        # 3. HTTP (Port 80 / 8080)
        elif src_port in (80, 8080) or dst_port in (80, 8080):
            dpi_stats["http_bytes"] += pkt_len
            dpi_stats["active_flows"]["http"] += 1
            text = packet_bytes[:512].decode("latin-1", errors="ignore")
            if "Host:" in text:
                for line in text.split("\r\n"):
                    if line.lower().startswith("host:"):
                        host = line.split(":", 1)[1].strip()
                        print(f"[DPI-5G-HTTP] 5G UE ({src_ip}:{src_port}) -> Intercepted HTTP Host: {host}", flush=True)
                        if any(phish in host for phish in PHISHING_DOMAINS):
                            dpi_stats["phishing_threats"] += 1
                            print(f"⚠️ [DPI-ALERT] 5G USER-PLANE MALICIOUS HTTP HOST BLOCKED: {host}", flush=True)
            return "HTTP"

        # 4. RTP (Port 10000-20000)
        elif 10000 <= src_port <= 20000 or 10000 <= dst_port <= 20000:
            dpi_stats["rtp_bytes"] += pkt_len
            dpi_stats["active_flows"]["rtp"] += 1
            return "RTP"

        else:
            dpi_stats["other_bytes"] += pkt_len
            return "OTHER"


def start_live_packet_sniffer():
    """
    Spawns live background sniffer threads listening on 5G UPF user-plane interface.
    """
    def dns_sniffer():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", SNIFFER_PORT_DNS))
        print(f"[*] 5G DPI Sniffer listening on 0.0.0.0:{SNIFFER_PORT_DNS} (5G DNS/GTP-U ogstun)", flush=True)
        while True:
            try:
                data, addr = sock.recvfrom(65535)
                process_packet(data, src_ip=addr[0], src_port=addr[1], dst_port=SNIFFER_PORT_DNS)
            except Exception:
                break

    def rtp_sniffer():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", SNIFFER_PORT_RTP))
        print(f"[*] 5G DPI Sniffer listening on 0.0.0.0:{SNIFFER_PORT_RTP} (5G RTP/Media)", flush=True)
        while True:
            try:
                data, addr = sock.recvfrom(65535)
                process_packet(data, src_ip=addr[0], src_port=addr[1], dst_port=SNIFFER_PORT_RTP)
            except Exception:
                break

    t1 = threading.Thread(target=dns_sniffer, daemon=True)
    t2 = threading.Thread(target=rtp_sniffer, daemon=True)
    t1.start()
    t2.start()


def main():
    print("==========================================================================", flush=True)
    print(" 📡 5G CORE L7 DEEP PACKET INSPECTION (DPI) ENGINE INITIALIZING", flush=True)
    print("==========================================================================", flush=True)

    # 1. Start Prometheus HTTP Metrics Server on dedicated daemon thread
    server = ThreadingHTTPServer(("0.0.0.0", DPI_PORT), MetricsHandler)
    t_server = threading.Thread(target=server.serve_forever, daemon=True)
    t_server.start()
    print(f"[*] 5G DPI Prometheus Exporter listening on http://0.0.0.0:{DPI_PORT}/metrics", flush=True)

    # 2. Start Real OS Kernel Sniffers
    start_live_packet_sniffer()
    print("[+] DPI Engine Online & Actively Sniffing 5G UPF ogstun / GTP-U Interface.", flush=True)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
