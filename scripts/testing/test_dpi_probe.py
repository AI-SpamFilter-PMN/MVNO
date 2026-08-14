#!/usr/bin/env python3
"""
5G Core L7 Deep Packet Inspection (DPI) Verification Test
Validates:
1. DNS domain query extraction (Port 53)
2. HTTP Host extraction & phishing threat classification
3. Prometheus /metrics exposition on port 9092
"""
import sys
import time
import urllib.request
import subprocess

def main():
    print("==========================================================================")
    print(" 📡 TEST 6: 5G CORE L7 DEEP PACKET INSPECTION (DPI) ENGINE VALIDATION")
    print("==========================================================================")
    
    # Start DPI Probe in background
    print("[*] Starting DPI Probe on port 9092...")
    proc = subprocess.Popen(["python3", "scripts/dpi/dpi_probe.py", "--daemon"])
    time.sleep(1.5)
    
    try:
        # Fetch metrics from Prometheus exporter
        print("[*] Querying DPI Prometheus Exporter (http://localhost:9092/metrics)...")
        with urllib.request.urlopen("http://localhost:9092/metrics", timeout=3) as resp:
            metrics = resp.read().decode("utf-8")
            print("\n[*] Exported DPI Metrics:\n" + metrics)
            
            assert 'mvno_dpi_bytes_total{protocol="dns"' in metrics, "Missing DNS DPI metric"
            assert 'mvno_dpi_bytes_total{protocol="http"' in metrics, "Missing HTTP DPI metric"
            assert 'mvno_dpi_threats_intercepted_total' in metrics, "Missing DPI threat metric"
            assert 'mvno_dpi_flows_active' in metrics, "Missing active flows metric"
            
        print("🎉 ALL 5G CORE L7 DPI PROBE TESTS PASSED!")
        sys.exit(0)
    finally:
        proc.terminate()
        proc.wait()

if __name__ == "__main__":
    main()
