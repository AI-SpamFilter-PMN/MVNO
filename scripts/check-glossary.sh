#!/usr/bin/env bash
# check-glossary.sh — read-only lint: every all-caps acronym in doc prose must
# be explained by docs/GLOSSARY.md or the pinned ALLOWLIST below.
#
#   bash scripts/check-glossary.sh          # exit 0 = clean, exit 1 = uncovered
#   bash scripts/check-glossary.sh -v       # verbose: show per-doc counts
#
# Not wired into CI (F5). Run after any docs edit — see ONBOARDING.md §8.

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Pinned non-acronyms / universal terms / protocol & SQL literals / English
# words / markdown callouts / artifact fragments. Built from the 2026-08-07
# corpus sweep; extend here (and consider a GLOSSARY.md row instead) if a real
# domain term ever lands in this list.
ALLOWLIST=(
  ACK AFTER AI AIR ALL ALWAYS AND API APT ASK BLOCK BLOCKED BYE CAPTCHA CELLS CI
  CLEAN COMMANDS CORRECTED CPU DB DEEP DEMO DIVE DNS ECC EINVAL ENGINE EOF ERROR
  EXIT EXPECT FAIL FAILED FALLBACK FIXED FROM GAPPED GET GLOSSARY GPU GSM GTP
  HSL HTTP HTTPS ID IMPORTANT IMPLEMENTED INTERCEPT INTENTIONALLY INVITE IO IP
  IPAM ISDN ISSUES JSON KB KEPT LIVE MANIFEST MASQUERADE MD5 MIC MUST MVP NAT
  NEW NIC NOT NOTE NULL OK ONBOARDING ONLINE OR OS OBSERVABILITY OSS PASS PCAP
  PCM PCMA PG PIKE POST POSTROUTING PPA PRAGMA PROBE PSI PURPOSE QUERY RAM RCA
  README REGISTER REMOVED REQUIRED RESPONSE RFC RHEL ROADMAP RX SELF SELECT
  SHAKEN SIGINT SLATE SM SOTA SQL STIR TCP TEST TIP TLV TM TPS TRANSCRIPT TUN
  TX UDP UI UL UP URL USB UTC WARN WARNING WER WITHOUT WS2 YAML
)

GLOSSARY="docs/GLOSSARY.md"

python3 - "$GLOSSARY" "${ALLOWLIST[@]}" "$@" <<'PYEOF'
import re
import sys

glossary_path = sys.argv[1]
args = sys.argv[2:]
verbose = "-v" in args
allowlist = set(a for a in args if not a.startswith("-"))
if "-v" in allowlist:
    allowlist.discard("-v")

keys = set()
for line in open(glossary_path, encoding="utf-8"):
    if line.startswith("| **"):
        key = line.split("|")[1].replace("*", "").strip()
        keys.add(key)

docs = sorted(["ONBOARDING.md", "README.md"] + __import__("glob").glob("docs/*.md"))
docs = [d for d in docs if d != glossary_path]

TOKEN = re.compile(r"\b[A-Z][A-Z0-9]+(?:[-/][A-Z0-9]+)*\b")
LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`]*`")
STEPREF = re.compile(r"^[A-Z][0-9]*(?:[-/](?:[A-Z][0-9]*|[0-9]+))*$")  # S1, N3, T6/T7, L1-2


def explained(tok):
    if tok in keys or tok in allowlist:
        return True
    if STEPREF.match(tok):  # step/terminal/interface refs, not acronyms
        return True
    base = tok.rstrip("0123456789")  # MS1, UE-1, NEA1 → MS, UE, NEA
    if base != tok and base and explained(base):
        return True
    for i in range(len(tok), 0, -1):  # longest known prefix + remainder
        if tok[:i] in keys or tok[:i] in allowlist or STEPREF.match(tok[:i]):
            rest = tok[i:].lstrip("-/")
            if not rest or rest.isdigit() or explained(rest):
                return True
    return False


uncovered = {}
for doc in docs:
    src = open(doc, encoding="utf-8").read()
    src = FENCE.sub(" ", src)
    src = INLINE.sub(" ", src)
    src = LINK.sub(r"\1", src)
    for tok in TOKEN.findall(src):
        if explained(tok):
            continue
        uncovered.setdefault(tok, 0)
        uncovered[tok] += 1
        if verbose:
            print(f"  {doc}: {tok}")

if uncovered:
    print(f"UNCOVERED ({len(uncovered)}): " + ", ".join(sorted(uncovered)))
    sys.exit(1)
print(f"✓ 0 uncovered — every all-caps acronym in prose is in GLOSSARY.md ({len(keys)} keys) or ALLOWLIST")
PYEOF
