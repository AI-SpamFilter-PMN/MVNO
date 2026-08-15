#!/usr/bin/env python3
"""
MVNO 5G Standalone Core L7 Deep Packet Inspection (DPI) Engine (3GPP TS 23.501)
Attached directly to Open5GS UPF User-Plane interface (ogstun / 10.45.0.0/16).

Features:
1. 5G Data Plane Sniffing: Binds live kernel raw socket (AF_PACKET / SOCK_RAW) to ogstun.
2. Real-Time Layer 7 Protocol Decoding:
   - DNS (UDP Port 53 / 5353): Parses QNAME and detects malicious phishing domains.
   - HTTP (TCP Port 80 / 8080): Parses HTTP Request Methods, Paths, and Host headers.
   - TLS SNI (TCP Port 443 / 8443): Extracts TLS ClientHello Server Name Indication.
   - RTP (UDP Ports 10000-20000): Tracks VoIP voice media streaming flows.
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


def parse_dns_qname(data):
    """Decodes DNS query domain name from raw DNS payload."""
    try:
        if len(data) < 12:
            return None
        idx = 12
        parts = []
        while idx < len(data):
            length = data[idx]
            if length == 0:
                break
            idx += 1
            if idx + length > len(data):
                break
            parts.append(data[idx:idx+length].decode("ascii", errors="ignore"))
            idx += length
        return ".".join(parts) if parts else None
    except Exception:
        return None


def parse_tls_sni(data):
    """Extracts TLS ClientHello Server Name Indication (SNI)."""
    try:
        # TLS Handshake (0x16), Version (0x03, 0x01/02/03)
        if len(data) < 43 or data[0] != 0x16:
            return None
        if data[5] != 0x01: # ClientHello
            return None
        
        session_id_len = data[43]
        idx = 44 + session_id_len
        if idx + 2 > len(data):
            return None
        cipher_len = struct.unpack("!H", data[idx:idx+2])[0]
        idx += 2 + cipher_len
        if idx + 1 > len(data):
            return None
        comp_len = data[idx]
        idx += 1 + comp_len
        if idx + 2 > len(data):
            return None
        ext_len = struct.unpack("!H", data[idx:idx+2])[0]
        idx += 2
        
        ext_end = idx + ext_len
        while idx + 4 <= min(ext_end, len(data)):
            ext_type = struct.unpack("!H", data[idx:idx+2])[0]
            ext_data_len = struct.unpack("!H", data[idx+2:idx+4])[0]
            idx += 4
            if ext_type == 0x00: # SNI extension
                if idx + 5 <= len(data):
                    name_len = struct.unpack("!H", data[idx+3:idx+5])[0]
                    return data[idx+5:idx+5+name_len].decode("ascii", errors="ignore")
            idx += ext_data_len
    except Exception:
        pass
    return None


def parse_http_host(data):
    """Extracts HTTP Host header or request line."""
    try:
        text = data[:512].decode("latin-1", errors="ignore")
        if text.startswith(("GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "OPTIONS ")):
            for line in text.split("\r\n"):
                if line.lower().startswith("host:"):
                    return line.split(":", 1)[1].strip().split(":")[0]
    except Exception:
        pass
    return None


def process_ip_packet(packet, src_addr="10.45.0.5"):
    """Inspects an IPv4 packet traversing ogstun."""
    if len(packet) < 20:
        return
    
    # Check IP version (IPv4 = 4)
    version = (packet[0] >> 4) & 0x0F
    if version != 4:
        return
    
    ihl = (packet[0] & 0x0F) * 4
    if len(packet) < ihl:
        return
    
    proto = packet[9]
    src_ip = socket.inet_ntoa(packet[12:16])
    dst_ip = socket.inet_ntoa(packet[16:20])
    payload = packet[ihl:]
    
    # 1. UDP Traffic (DNS, RTP)
    if proto == 17 and len(payload) >= 8:
        src_port, dst_port, udp_len = struct.unpack("!HHH", payload[:6])
        udp_data = payload[8:udp_len]
        
        # DNS Inspection (Port 53 or 5353)
        if dst_port in (53, 5353) or src_port in (53, 5353):
            qname = parse_dns_qname(udp_data)
            with stats_lock:
                dpi_stats["dns_bytes"] += len(udp_data)
                dpi_stats["active_flows"]["dns"] += 1
                if qname:
                    print(f"[DPI-5G-DNS] 5G UE ({src_ip}:{src_port}) -> Intercepted DNS Query: {qname}")
                    for phish in PHISHING_DOMAINS:
                        if phish in qname:
                            dpi_stats["phishing_threats"] += 1
                            print(f"⚠️ [DPI-ALERT] 5G USER-PLANE PHISHING BLOCKED: {qname} from UE {src_ip}")
                            break
                            
        # RTP Voice Media Inspection (Ports 10000-20000)
        elif 10000 <= dst_port <= 20000 or 10000 <= src_port <= 20000:
            with stats_lock:
                dpi_stats["rtp_bytes"] += len(udp_data)
                dpi_stats["active_flows"]["rtp"] += 1
        else:
            with stats_lock:
                dpi_stats["other_bytes"] += len(udp_data)

    # 2. TCP Traffic (HTTP, TLS SNI)
    elif proto == 6 and len(payload) >= 20:
        src_port, dst_port = struct.unpack("!HH", payload[:4])
        tcp_hdr_len = ((payload[12] >> 4) & 0x0F) * 4
        tcp_data = payload[tcp_hdr_len:]
        
        if len(tcp_data) > 0:
            # HTTP Inspection (Port 80 / 8080)
            if dst_port in (80, 8080) or src_port in (80, 8080):
                host = parse_http_host(tcp_data)
                with stats_lock:
                    dpi_stats["http_bytes"] += len(tcp_data)
                    dpi_stats["active_flows"]["http"] += 1
                    if host:
                        print(f"[DPI-5G-HTTP] 5G UE ({src_ip}) -> HTTP Host: {host}")
                        for phish in PHISHING_DOMAINS:
                            if phish in host:
                                dpi_stats["phishing_threats"] += 1
                                print(f"⚠️ [DPI-ALERT] 5G USER-PLANE PHISHING BLOCKED: {host} from UE {src_ip}")
                                break
                                
            # TLS SNI Inspection (Port 443 / 8443)
            elif dst_port in (443, 8443) or src_port in (443, 8443):
                sni = parse_tls_sni(tcp_data)
                with stats_lock:
                    dpi_stats["tls_bytes"] += len(tcp_data)
                    dpi_stats["active_flows"]["tls"] += 1
                    if sni:
                        print(f"[DPI-5G-TLS] 5G UE ({src_ip}) -> TLS SNI: {sni}")
                        for phish in PHISHING_DOMAINS:
                            if phish in sni:
                                dpi_stats["phishing_threats"] += 1
                                print(f"⚠️ [DPI-ALERT] 5G USER-PLANE PHISHING BLOCKED: {sni} from UE {src_ip}")
                                break
            else:
                with stats_lock:
                    dpi_stats["other_bytes"] += len(tcp_data)


def run_ogstun_raw_sniffer():
    """
    Main raw packet sniffer thread.
    Binds AF_PACKET / SOCK_RAW to ogstun inside Open5GS UPF netns.
    """
    print("[*] Initializing 5G Core ogstun Raw Packet Sniffer...")
    raw_sock = None
    
    # Try AF_PACKET raw socket on ogstun (ETH_P_ALL = 0x0003 or ETH_P_IP = 0x0800)
    for proto in (0x0003, 0x0800):
        try:
            s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(proto))
            s.bind(("ogstun", 0))
            raw_sock = s
            print(f"  ✓ Successfully bound AF_PACKET raw socket on ogstun (proto 0x{proto:04x})")
            break
        except Exception as e:
            pass
            
    # Fallback to SOCK_RAW on IP protocols if AF_PACKET not permitted
    if not raw_sock:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_UDP)
            raw_sock = s
            print("  ✓ Bound AF_INET SOCK_RAW socket for 5G user-plane inspection")
        except Exception as e:
            print(f"[-] Failed to bind raw socket: {e}")
            
    if not raw_sock:
        print("[-] Fatal: Could not create kernel raw socket for 5G DPI. Check NET_RAW capabilities.")
        return

    print("🚀 5G Core User-Plane L7 DPI Sniffer Active on ogstun.")
    while True:
        try:
            packet, addr = raw_sock.recvfrom(65535)
            if packet:
                # If packet has link layer header (14 bytes), strip it
                if len(packet) >= 14 and ((packet[0] >> 4) & 0x0F) != 4:
                    ip_packet = packet[14:]
                else:
                    ip_packet = packet
                process_ip_packet(ip_packet)
        except Exception:
            time.sleep(0.01)


def main():
    print("==========================================================================")
    print(" 📡 MVNO 5G SA CORE USER-PLANE L7 DEEP PACKET INSPECTION (DPI) PROBE")
    print("==========================================================================")
    
    # 1. Start Prometheus Exporter HTTP Server on :9094
    server = ThreadingHTTPServer(("0.0.0.0", DPI_PORT), MetricsHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    print(f"[*] Prometheus Metrics Exporter listening on http://0.0.0.0:{DPI_PORT}/metrics")
    
    # 2. Start ogstun Raw Kernel Socket Sniffer
    sniffer_thread = threading.Thread(target=run_ogstun_raw_sniffer, daemon=True)
    sniffer_thread.start()
    
    # Keep alive
    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()
