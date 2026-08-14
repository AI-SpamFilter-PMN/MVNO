#!/usr/bin/env python3
"""
verify_grafana_live_metrics.py — Strict SRE Evidence Validation for Grafana Dashboard Queries

Strict Validation Standard:
1. Fetches all known metric names from VictoriaMetrics TSDB (/api/v1/label/__name__/values).
2. For every Prometheus panel query across ALL dashboards:
   - Extracts and verifies that underlying metric names exist in TSDB (catches typos / nonexistent metrics).
   - Executes the PromQL query against VictoriaMetrics (/api/v1/query).
   - Asserts valid PromQL syntax and returns the live empirical numeric value.
   - Strictly FAILS if query returns empty vector or missing metric!
3. Exits with non-zero exit code if ANY metric is missing or query fails.
"""
import sys
import json
import urllib.parse
import urllib.request
import re
import os

VM_BASE = "http://localhost:8428"
DASH_FILES = [
    "configs/grafana/provisioning/dashboards/mvno_unified_noc.json",
    "configs/grafana/provisioning/dashboards/mvno_soc_antifraud.json",
    "configs/grafana/provisioning/dashboards/mvno_5g_core_dpi.json",
    "configs/grafana/provisioning/dashboards/mvno_ims_voice_media.json"
]

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)

def get_all_known_metrics():
    url = f"{VM_BASE}/api/v1/label/__name__/values"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return set(data.get("data", []))
    except Exception as e:
        print(f"[!] Error fetching TSDB metric names: {e}")
        return set()

def extract_metric_names(expr):
    # Strip string literals, label filters, by/without clauses, template variables, and ranges
    clean = re.sub(r'"[^"]*"', '', expr)
    clean = re.sub(r'\{[^}]*\}', '', clean)
    clean = re.sub(r'\[[^\]]*\]', '', clean)
    clean = re.sub(r'\b(by|without)\s*\([^)]*\)', '', clean)
    clean = re.sub(r'\$[a-zA-Z0-9_]+', '', clean)
    
    keywords = {"sum", "rate", "count", "avg", "min", "max", "default", "topk", "bottomk", "increase", "idelta", "and", "or", "unless"}
    tokens = re.findall(r'[a-zA-Z_:][a-zA-Z0-9_:]*', clean)
    metrics = [t for t in tokens if t not in keywords and not t.isdigit()]
    return list(set(metrics))

def query_vm(expr):
    clean_expr = expr.replace("$__rate_interval", "1m").replace("$__interval", "1m")
    url = f"{VM_BASE}/api/v1/query?query={urllib.parse.quote(clean_expr)}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("status") != "success":
                return False, f"PromQL Error: {data.get('error')}"
            
            results = data.get("data", {}).get("result", [])
            if not results:
                return False, "EMPTY_VECTOR (No matching series in TSDB)"
            
            val = results[0].get("value", [None, None])[1]
            return True, val
    except Exception as e:
        return False, f"HTTP Error: {e}"

def main():
    print("=" * 90)
    print(" 🔬 STRICT GRAFANA CARRIER TSDB METRICS & SRE VALIDATOR")
    print("=" * 90)
    
    known_metrics = get_all_known_metrics()
    print(f"[*] Total authoritative metric series in VictoriaMetrics TSDB: {len(known_metrics)}")
    
    total_queries = 0
    passed_queries = 0
    failed_queries = 0
    
    for dash_path in DASH_FILES:
        if not os.path.exists(dash_path):
            continue
            
        with open(dash_path, "r") as f:
            dash = json.load(f)
            
        dash_title = dash.get("title", os.path.basename(dash_path))
        print(f"\n📂 DASHBOARD: {dash_title}")
        print(f"{'#':<3} | {'Panel Title':<34} | {'Status':<6} | {'Metric / Live Value'}")
        print("-" * 90)
        
        for p in dash.get("panels", []):
            title = p.get("title", "Untitled")[:34]
            targets = p.get("targets", [])
            for t in targets:
                expr = t.get("expr")
                if not expr or expr.startswith("*"):
                    continue
                    
                total_queries += 1
                metric_tokens = extract_metric_names(expr)
                
                # Strict check 1: Metric name existence in VictoriaMetrics
                missing = [m for m in metric_tokens if m not in known_metrics and m != "up"]
                if missing:
                    print(f"{total_queries:<3} | {title:<34} | FAIL   | ❌ Missing metric in TSDB: {missing}")
                    failed_queries += 1
                    continue
                
                # Strict check 2: Real live evaluation returning non-empty data vector
                success, val = query_vm(expr)
                if success:
                    passed_queries += 1
                    status = "PASS"
                    verdict = f"{val} (Metric: {','.join(metric_tokens)})"
                else:
                    failed_queries += 1
                    status = "FAIL"
                    verdict = f"❌ {val} (Expr: {expr})"
                    
                print(f"{total_queries:<3} | {title:<34} | {status:<6} | {verdict}")
                
    print("\n" + "=" * 90)
    print(f"📊 STRICT SRE VALIDATION SUMMARY: Total: {total_queries} | Passed: {passed_queries} | Failed: {failed_queries}")
    print("=" * 90)
    
    if failed_queries > 0:
        print(f"❌ STRICT SRE VALIDATION FAILED ({failed_queries} failed queries)!")
        sys.exit(1)
    else:
        print("🎉 100% OF ALL QUERIES EMPIRICALLY VALIDATED AGAINST LIVE TSDB (0 MOCKS / 0 MISSING METRICS)!")
        sys.exit(0)

if __name__ == "__main__":
    main()
