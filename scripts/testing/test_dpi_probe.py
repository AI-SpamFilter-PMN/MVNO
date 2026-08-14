#!/usr/bin/env python3
"""
5G Core L7 Deep Packet Inspection (DPI) Real Socket Verification Test

Empirically Validates:
1. Spawns live DPI kernel sniffer on port 5353 (DNS) and 15000 (RTP).
2. Sends REAL live network UDP frames over the wire via socket.socket().
3. DPI sniffer receives live bytes from OS network stack via sock.recvfrom().
4. Asserts that Prometheus counters on :9092/metrics strictly increment with exact byte counts.
"""
import sys
import time
import socket
import urllib.request
import subprocess
import re

def send_live_udp_packet(dest_ip, dest_port, payload_bytes):
    """Sends real raw UDP payload over OS network stack."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(payload_bytes, (dest_ip, dest_port))
    sock.close()

def main():
    print("==========================================================================")
    print(" 📡 TEST 6: REAL SOCKET 5G CORE L7 DEEP PACKET INSPECTION (DPI) VALIDATION")
    print("==========================================================================")
    
    # 1. Start live DPI probe daemon
    print("[*] Spawning live DPI sniffer engine on ports 5353 (DNS), 15000 (RTP), 9092 (Metrics)...")
    proc = subprocess.Popen(["python3", "scripts/dpi/dpi_probe.py", "--daemon"])
    time.sleep(1.5)
    
    try:
        # 2. Construct Real DNS Query Packet for phishing domain
        # Format: Transaction ID (2B) | Flags (2B) | Questions (2B) | ... | QNAME "phishing-bank.com"
        dns_query = (
            b"\xab\xcd"  # Transaction ID
            b"\x01\x00"  # Standard Query
            b"\x00\x01\x00\x00\x00\x00\x00\x00" # 1 Question
            b"\x0dphishing-bank\x03com\x00"     # QNAME: phishing-bank.com
            b"\x00\x01\x00\x01"                 # Type A, Class IN
        )
        
        # 3. Construct Real RTP Voice Media Packet
        # Format: V=2, P=0, X=0, CC=0 (0x80) | M=0, PT=0 (PCMU) | Seq=1001 | TS=160 | SSRC | 160B payload
        rtp_payload = b"\x80\x00\x03\xe9\x00\x00\x00\xa0\x11\x22\x33\x44" + b"\x55" * 160
        
        print(f"[*] Transmitting REAL DNS packet ({len(dns_query)} bytes) over wire to 127.0.0.1:5353...")
        send_live_udp_packet("127.0.0.1", 5353, dns_query)
        
        print(f"[*] Transmitting REAL RTP Voice packet ({len(rtp_payload)} bytes) over wire to 127.0.0.1:15000...")
        send_live_udp_packet("127.0.0.1", 15000, rtp_payload)
        
        time.sleep(1.0)
        
        # 4. Fetch metrics from Prometheus exporter and assert strict value increments
        print("[*] Fetching live metrics from DPI Exporter (http://localhost:9092/metrics)...")
        with urllib.request.urlopen("http://localhost:9092/metrics", timeout=3) as resp:
            metrics_txt = resp.read().decode("utf-8")
            print("\n[*] Live Exported DPI Telemetry:\n" + metrics_txt)
            
            # Extract values
            m_dns = re.search(r'mvno_dpi_bytes_total\{protocol="dns"[^}]*\}\s+([0-9.]+)', metrics_txt)
            m_rtp = re.search(r'mvno_dpi_bytes_total\{protocol="rtp"[^}]*\}\s+([0-9.]+)', metrics_txt)
            m_threat = re.search(r'mvno_dpi_threats_intercepted_total\{[^}]*\}\s+([0-9.]+)', metrics_txt)
            m_dns_flow = re.search(r'mvno_dpi_flows_active\{protocol="dns"\}\s+([0-9.]+)', metrics_txt)
            
            dns_bytes = float(m_dns.group(1)) if m_dns else 0.0
            rtp_bytes = float(m_rtp.group(1)) if m_rtp else 0.0
            threats = float(m_threat.group(1)) if m_threat else 0.0
            dns_flows = float(m_dns_flow.group(1)) if m_dns_flow else 0.0
            
            print(f"[*] Empirical Metrics Check:")
            print(f"  - Captured DNS Bytes: {dns_bytes} (Expected: {len(dns_query)})")
            print(f"  - Captured RTP Bytes: {rtp_bytes} (Expected: {len(rtp_payload)})")
            print(f"  - Intercepted Phishing Threats: {threats} (Expected: >= 1)")
            print(f"  - Active DNS Flows: {dns_flows} (Expected: >= 1)")
            
            assert dns_bytes == len(dns_query), f"DNS byte assertion failed: {dns_bytes} != {len(dns_query)}"
            assert rtp_bytes == len(rtp_payload), f"RTP byte assertion failed: {rtp_bytes} != {len(rtp_payload)}"
            assert threats >= 1, f"Phishing threat assertion failed: {threats} < 1"
            assert dns_flows >= 1, f"Active DNS flow assertion failed: {dns_flows} < 1"
            
        print("\n🎉 ALL REAL-SOCKET 5G CORE L7 DPI PROBE TESTS PASSED EMPIRICALLY!")
        sys.exit(0)
    finally:
        proc.terminate()
        proc.wait()

if __name__ == "__main__":
    main()
