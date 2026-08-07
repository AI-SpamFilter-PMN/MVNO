#!/usr/bin/env bash
# ==============================================================================
# vendor-bundle.sh — Surgical air-gapped vendor bundle (no network required)
# ==============================================================================
# Repackages the local container-image store into the versioned tarballs that
# bootstrap.sh SAVE_IMAGES expects (vendor/docker/<key>.tar), replaces the stale
# unversioned tars, and regenerates vendor/checksums/sha256sums.txt.
#
# Unlike a full `bootstrap.sh` re-run this needs NO internet: every image must
# already exist locally (compose pins + build deps). It is the "ship-ready"
# producer for the air-gapped runbook in docs/deployment_guide.md.
#
# Usage: ./scripts/vendor-bundle.sh
# Exit 0 only if all SAVE_IMAGES keys are packaged and checksums regenerate.
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

DOCKER_CMD="${DOCKER_CMD:-podman}"
if ! command -v "$DOCKER_CMD" >/dev/null 2>&1; then
    echo "ERROR: ${DOCKER_CMD} not found — pass DOCKER_CMD=docker if needed"
    exit 1
fi

VENDOR_DIR="${PROJECT_DIR}/vendor"
TAR_DIR="${VENDOR_DIR}/docker"

# Mirror bootstrap.sh SAVE_IMAGES exactly (single source of truth for the bundle)
declare -A SAVE_IMAGES=(
    ["mongo-7.0"]="mongo:7.0"
    ["percona-mongodb_exporter-0.41"]="percona/mongodb_exporter:0.41"
    ["drachtio-rtpengine-mr9.4.0.0"]="drachtio/rtpengine:mr9.4.0.0"
    ["mvno-kamailio-5.7.2"]="mvno-kamailio:5.7.2"
    ["victoria-metrics-v1.147.0"]="victoriametrics/victoria-metrics:v1.147.0"
    ["vmagent-v1.147.0"]="victoriametrics/vmagent:v1.147.0"
    ["grafana-oss-11.6.0"]="grafana/grafana-oss:11.6.0"
    ["debian-bookworm-slim"]="debian:bookworm-slim"
    ["python-3.11-alpine"]="python:3.11-alpine"
    ["eclipse-temurin-21-jre"]="eclipse-temurin:21-jre"
    ["alpine-3.19"]="alpine:3.19"
    ["node-20-alpine"]="node:20-alpine"
    ["timberio-vector-0.44.0-alpine"]="timberio/vector:0.44.0-alpine"
    ["mvno-osmo-smsc-1.0.0"]="mvno-osmo-smsc:1.0.0"
    ["mvno-telecom-api-1.0.0"]="mvno-telecom-api:1.0.0"
    ["mvno-2g-core-1.0.0"]="mvno-2g-core:1.0.0"
    ["mvno-2g-ms-1.0.0"]="mvno-2g-ms:1.0.0"
    ["maven-3.9-eclipse-temurin-21"]="maven:3.9-eclipse-temurin-21"
    ["mvno-open5gs-2.8.0"]="mvno-open5gs:2.8.0"
    ["mvno-open5gs-webui-2.8.0"]="mvno-open5gs-webui:2.8.0"
    ["mvno-ueransim-3.2.6"]="mvno-ueransim:3.2.6"
    ["mvno-baresip-1.0.0"]="mvno-baresip:1.0.0"
)

# Resolve a short image ref to a local store entry, trying the prefixes podman
# uses when saving (docker.io/library/ for upstream, docker.io/, localhost/ for
# locally-built). Returns "" if the image is not in the local store at all.
resolve_image() {
    local ref="$1" cand
    if $DOCKER_CMD image exists "$ref" 2>/dev/null; then echo "$ref"; return 0; fi
    for cand in "docker.io/library/${ref}" "docker.io/${ref}" "localhost/${ref}"; do
        if $DOCKER_CMD image exists "$cand" 2>/dev/null; then echo "$cand"; return 0; fi
    done
    # maven tag drift: local store may carry maven:3.9.9-... while the key pins
    # maven:3.9-... — tag the newest local 3.9.x maven to the pinned name.
    if [[ "${ref}" == maven:* ]]; then
        local latest
        latest=$($DOCKER_CMD images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E '^(docker.io/library/)?maven:3\.9([^:]*)$' | head -1)
        if [ -n "$latest" ]; then
            $DOCKER_CMD tag "$latest" "$ref" >/dev/null 2>&1
            echo "  [maven] retagged ${latest} -> ${ref}"
            echo "$ref"; return 0
        fi
    fi
    return 1
}

mkdir -p "${TAR_DIR}" "${VENDOR_DIR}/checksums"
echo "╔══════════════════════════════════════════════╗"
echo "║   MVNO Vendor Bundle (offline, surgical)     ║"
echo "╚══════════════════════════════════════════════╝"

MISSING=0
for name in "${!SAVE_IMAGES[@]}"; do
    img="${SAVE_IMAGES[$name]}"
    out="${TAR_DIR}/${name}.tar"
    resolved="$(resolve_image "$img" || true)"
    if [ -z "$resolved" ]; then
        echo "  ✗ MISSING locally: ${img} — cannot bundle (run online bootstrap.sh first)"
        MISSING=1
        continue
    fi
    if $DOCKER_CMD image exists "$img" 2>/dev/null && [ "$resolved" != "$img" ]; then
        $DOCKER_CMD tag "$resolved" "$img" >/dev/null 2>&1
    fi
    # podman save refuses to overwrite an existing tar ("docker-archive doesn't
    # support modifying existing images", rc=125) — drop any stale copy first.
    rm -f "$out"
    $DOCKER_CMD save "$resolved" -o "$out" >/dev/null 2>&1
    echo "  ✓ saved ${name}.tar <- ${resolved}"
done

if [ "$MISSING" -ne 0 ]; then
    echo "ERROR: ${MISSING} SAVE_IMAGES image(s) absent from the local store."
    echo "Resolve on an online machine (bootstrap.sh or podman pull) then re-run."
    exit 1
fi

# Remove stale/unversioned tars that are not part of the bundle (old bootstrap
# produced e.g. mongo-8.0.tar, grafana-oss-latest.tar, mvno-kamailio.tar …).
echo ""
echo "=== Removing stale tarballs not in SAVE_IMAGES ==="
for tar in "${TAR_DIR}"/*.tar; do
    [ -f "$tar" ] || continue
    base="$(basename "$tar" .tar)"
    if [ -z "${SAVE_IMAGES[$base]:-}" ]; then
        rm -f "$tar"
        echo "  removed ${base}.tar"
    fi
done

# Remove empty pip subdirs (e.g. pip/telecom-api is mkdir-only in bootstrap.sh;
# nothing ships there, so it must not generate checksum entries)
echo ""
echo "=== Removing empty vendored directories ==="
find "${VENDOR_DIR}/pip" -type d -empty -delete 2>/dev/null || true

# Regenerate checksums (identical logic to bootstrap.sh Step 8, but with paths
# RELATIVE to the project root so the file is portable: on the air-gapped
# machine `cd <repo> && sha256sum -c vendor/checksums/...` works regardless of
# where the repo was unpacked).
echo ""
echo "=== Regenerating checksums ==="
(cd "$PROJECT_DIR" && find vendor -type f ! -path 'vendor/checksums/*' ! -path 'vendor/logs/*' -exec sha256sum {} \;) \
    > "${VENDOR_DIR}/checksums/sha256sums.txt"
echo "  wrote vendor/checksums/sha256sums.txt ($(wc -l < "${VENDOR_DIR}/checksums/sha256sums.txt") entries)"

# ─── Gates ────────────────────────────────────────────
echo ""
echo "=== Gates ==="
GATE_FAIL=0
n_tars=0
for tar in "${TAR_DIR}"/*.tar; do [ -f "$tar" ] && n_tars=$((n_tars + 1)); done
echo "  tars: ${n_tars}"
[ "$n_tars" -eq "${#SAVE_IMAGES[@]}" ] || { echo "  ✗ expected ${#SAVE_IMAGES[@]} tars"; GATE_FAIL=1; }
if (cd "$PROJECT_DIR" && sha256sum -c "${VENDOR_DIR}/checksums/sha256sums.txt" >/dev/null 2>&1); then
    echo "  sha256sum -c: all OK"
else
    echo "  ✗ sha256sum -c: mismatches"; GATE_FAIL=1
fi
echo ""
if [ "$GATE_FAIL" -ne 0 ]; then
    echo "RESULT: ✗ bundle gates failed — fix and re-run"
    exit 1
fi
du -sh "${VENDOR_DIR}"
echo "RESULT: ✓ bundle ready — tar czf mvno-offline.tar.gz vendor/ to ship"
exit 0
