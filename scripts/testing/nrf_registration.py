#!/usr/bin/env python3
# ==============================================================================
# nrf_registration.py — ROADMAP item 5: Open5GS SBI registration evaluation
# ==============================================================================
# Queries the NRF Nnrf_NFM discovery API (HTTP/2 h2c on nrf:7777, via the
# curl-capable mvno-grafana probe container on mvno_net) and asserts the
# expected control-plane NF set is registered.
#
# Exit codes:
#   0  -> all expected NFs registered (prints sorted nfType list)
#   1  -> one or more expected NFs missing (prints "MISSING: <types>")
#   2  -> NRF query failed (nrf/grafana down, HTTP/2 probe broken)
# ==============================================================================
import json
import subprocess
import sys

EXPECTED = {"AMF", "AUSF", "BSF", "NRF", "NSSF", "PCF", "SMF", "UDM", "UDR"}
NRF_BASE = "http://mvno-nrf:7777"
PROBE = ["podman", "exec", "mvno-grafana", "curl", "-s", "-m", "3",
         "--http2-prior-knowledge"]


def nrf_curl(path):
    # hrefs from the NRF listing are absolute (http://nrf:7777/...) — use as-is.
    url = path if path.startswith("http") else NRF_BASE + path
    out = subprocess.run(PROBE + [url], capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else ""


def main():
    try:
        listing = json.loads(nrf_curl("/nnrf-nfm/v1/nf-instances"))
        hrefs = [item["href"] for item in listing["_links"]["item"]]
        types = sorted({json.loads(nrf_curl(h)).get("nfType", "?") for h in hrefs})
    except (ValueError, KeyError, json.JSONDecodeError):
        print("NRF-QUERY-FAIL", file=sys.stderr)
        return 2

    missing = sorted(EXPECTED - set(types))
    print(" ".join(types))
    if missing:
        print("MISSING:" + " ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
