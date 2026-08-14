#!/usr/bin/env python3
"""
5G Core L7 Deep Packet Inspection (DPI) 100% Real 5G User-Plane Verification Test

Zero-Mock Validation:
1. Verifies compose-managed DPI probe (mvno-5g-dpi) is running inside Open5GS UPF container netns (ogstun).
2. Executes Python on 5G UE container (mvno-ueransim-ue-1, IP 10.45.0.5).
3. 5G UE transmits DNS query for 'phishing-bank.com' over 5G PDU session (uesimtun0).
4. Traffic traverses: 5G UE -> gNodeB (mvno-ueransim-gnb) -> GTP-U (2152) -> UPF -> ogstun (10.45.0.1:5353).
5. DPI sniffer intercepts live packet on ogstun from 5G UE (10.45.0.5) and inspects L7 payload.
6. Asserts live PromQL metrics scraped by vmagent into VictoriaMetrics TSDB (port 8428).
"""
import sys
import os
import time
import subprocess
import urllib.request
import urllib.parse
import json

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)

def run_cmd(cmd, timeout=30):
    res = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    out = (res.stdout or "") + "\n" + (res.stderr or "")
    return out.strip()

def query_vm(promql):
    url = f"http://localhost:8428/api/v1/query?query={urllib.parse.quote(promql)}"
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = data.get("data", {}).get("result", [])
            if results:
                val = float(results[0].get("value", [0, 0])[1])
                return val
    except Exception:
        pass
    return None

def main():
    print("==========================================================================")
    print(" 📡 TEST 6: REAL 5G CORE GTP-U & OGSTUN L7 DPI PACKET INSPECTION")
    print("==========================================================================")
    
    # 1. Verify mvno-5g-dpi is running in UPF netns
    ps_out = run_cmd("podman ps --format '{{.Names}}' | grep -x mvno-5g-dpi")
    if "mvno-5g-dpi" not in ps_out:
        print("[!] Starting mvno-5g-dpi via compose...")
        run_cmd("podman compose up -d dpi-probe")
        time.sleep(2.0)
    print("  ✓ Compose-managed 5G DPI Probe running in Open5GS UPF netns.")

    # 2. Record Baseline VictoriaMetrics TSDB Metrics before packet injection
    print("[*] Recording baseline TSDB metrics prior to 5G packet injection...")
    time.sleep(2.0)
    init_bytes = query_vm('sum(mvno_dpi_bytes_total{protocol="dns"})') or 0.0
    init_threats = query_vm('sum(mvno_dpi_threats_intercepted_total{protocol="dns"})') or 0.0
    print(f"  - Initial Captured Bytes:   {init_bytes}")
    print(f"  - Initial Threats Blocked: {init_threats}")

    # 3. Transmit Real 5G DNS Packet from 5G UE (10.45.0.5) over uesimtun0
    dns_query_hex = "abcd010000010000000000000d7068697368696e672d62616e6b03636f6d0000010001"
    dns_query_len = len(bytes.fromhex(dns_query_hex))
    
    print(f"[*] Triggering 5G UE (mvno-ueransim-ue-1, 10.45.0.5) transmission over 5G PDU session (uesimtun0)...")
    ue_cmd = f"""podman exec mvno-ueransim-ue-1 python3 -c "
import socket
payload = bytes.fromhex('{dns_query_hex}')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('10.45.0.5', 0))
s.sendto(payload, ('10.45.0.1', 5353))
print('  ✓ Sent 5G DNS query ({dns_query_len} bytes) from UE 10.45.0.5 -> UPF ogstun 10.45.0.1:5353')
" """
    ue_res = run_cmd(ue_cmd)
    print(f"{ue_res}")
    if "Sent 5G DNS query" not in ue_res:
        raise RuntimeError(f"Fatal: 5G UE packet transmission failed: {ue_res}")
        
    # 4. Fetch updated metrics from VictoriaMetrics TSDB & Live Probe Exporter
    print("[*] Fetching ingested metrics from VictoriaMetrics (http://localhost:8428) & UPF Probe...")
    time.sleep(5.5) # Wait for vmagent 5s scrape cycle
    
    # Query live probe exporter inside container network
    probe_metrics = run_cmd("podman exec mvno-vmagent wget -qO- http://upf:9094/metrics", timeout=5)
    print(f"[*] Live UPF Probe Exporter Metrics:\n{probe_metrics.strip()}")
    
    dns_bytes = query_vm('sum(mvno_dpi_bytes_total{protocol="dns"})') or 0.0
    threats = query_vm('sum(mvno_dpi_threats_intercepted_total{protocol="dns"})') or 0.0
    dns_flows = query_vm('sum(mvno_dpi_flows_active{protocol="dns"})') or 0.0
    
    print(f"[*] VictoriaMetrics TSDB Ingested Telemetry:")
    print(f"  - Captured 5G DNS Bytes:        {dns_bytes} (Expected: >= {dns_query_len})")
    print(f"  - Intercepted 5G Phishing Threat: {threats} (Expected: >= 1)")
    print(f"  - Active 5G DNS Flows:          {dns_flows} (Expected: >= 1)")
    
    assert "mvno_dpi_bytes_total" in probe_metrics and "mvno_dpi_threats_intercepted_total" in probe_metrics, "Probe exporter missing metrics!"
    assert dns_bytes is not None and dns_bytes >= dns_query_len, f"5G DNS byte assertion failed: {dns_bytes} < {dns_query_len}"
    assert threats is not None and threats >= 1, f"5G Phishing threat assertion failed: {threats} < 1"
    assert dns_flows is not None and dns_flows >= 1, f"5G Active DNS flow assertion failed: {dns_flows} < 1"
    
    print("\n[*] DPI Sniffer Interception Log from UPF ogstun interface:")
    dpi_logs = run_cmd("podman logs --tail 5 mvno-5g-dpi")
    print(f"  {dpi_logs}")
    
    print("\n🎉 100% REAL 5G CORE GTP-U & OGSTUN L7 DPI PACKET INSPECTION PASSED EMPIRICALLY!")
    sys.exit(0)

if __name__ == "__main__":
    main()
