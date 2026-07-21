#!/usr/bin/env bash
# bootstrap.sh — Run ONCE with internet to vendor all dependencies
#
# Detects OS & container runtime (docker/podman), installs what's missing,
# then downloads everything needed for fully offline builds:
#   - Docker images (pulled + custom-built, saved as tarballs)
#   - pip wheels (for telecom-api, vosk-worker)
#   - Vosk speech model
#   - UERANSIM source tarball
#   - Open5GS WebUI source
#
# Usage:  ./scripts/bootstrap.sh
# Output: vendor/  (ship this to air-gapped machines)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VENDOR_DIR="$PROJECT_DIR/vendor"
LOG_DIR="$VENDOR_DIR/logs"

UERANSIM_VERSION="3.2.6"
OPEN5GS_VERSION="2.7.0"
OPEN5GS_DIR="$PROJECT_DIR/configs/open5gs"

# ─── Accumulators ───────────────────────────────────────
SUCCESSES=()
FAILURES=()

# ─── try_log: run a command, log + show output, accumulate success/failure ───
# Usage: try_log "step label" "command string"
try_log() {
    local label="$1" cmd="$2"
    mkdir -p "$LOG_DIR"
    local logfile="$LOG_DIR/${label//\//_}.log"
    echo ""
    echo "=== $label ==="
    eval "$cmd" 2>&1 | tee "$logfile"
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -eq 0 ]; then
        echo "  ✓ $label"
        SUCCESSES+=("$label")
    else
        echo "  ✗ $label (see $logfile)"
        FAILURES+=("$label")
    fi
}

try_log_quiet() {
    local label="$1" cmd="$2"
    mkdir -p "$LOG_DIR"
    local logfile="$LOG_DIR/${label//\//_}.log"
    if eval "$cmd" >> "$logfile" 2>&1; then
        SUCCESSES+=("$label")
    else
        echo "  ✗ $label (see $logfile)"
        FAILURES+=("$label")
    fi
}

# ─── OS Detection ────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            arch|endeavouros|cachyos|manjaro|artix) OS="arch" ;;
            debian|ubuntu|pop|linuxmint|elementary|zorin) OS="debian" ;;
            fedora|rhel|centos|rocky|alma) OS="fedora" ;;
            alpine) OS="alpine" ;;
            opensuse*|suse) OS="suse" ;;
            *) OS="unknown" ;;
        esac
    elif [ "$(uname)" = "Darwin" ]; then
        OS="macos"
    else
        OS="unknown"
    fi
    echo "Detected OS: $ID ($OS)"
}

# ─── Install system packages idempotently ───────────────
install_packages() {
    local pkgs=("$@")
    echo "  Installing: ${pkgs[*]}"
    case "$OS" in
        arch)
            sudo pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        debian)
            sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${pkgs[@]}" ;;
        fedora)
            sudo dnf install -y "${pkgs[@]}" ;;
        macos)
            brew install "${pkgs[@]}" ;;
        *)
            echo "  [WARN] Unknown OS — install manually: ${pkgs[*]}"
            return 1 ;;
    esac
}

# ─── Container Runtime Detection & Install ─────────────
detect_runtime() {
    if command -v docker &>/dev/null; then
        RUNTIME="docker"
        if docker info &>/dev/null 2>&1; then
            DOCKER_CMD="docker"
            COMPOSE_CMD="docker compose"
        elif sg docker -c "docker info" &>/dev/null 2>&1; then
            echo "  Docker accessible via sg docker"
            docker_cmd()  { sg docker -c "docker $*"; }
            compose_cmd() { sg docker -c "docker compose $*"; }
            DOCKER_CMD="docker_cmd"
            COMPOSE_CMD="compose_cmd"
        else
            echo "  [WARN] Docker daemon not accessible — builds may fail"
            DOCKER_CMD="docker"
            COMPOSE_CMD="docker compose"
        fi
        echo "Runtime: docker (found at $(command -v docker))"
        install_packages docker-buildx 2>/dev/null || true
        return 0
    fi
    if command -v podman &>/dev/null; then
        RUNTIME="podman"
        DOCKER_CMD="podman"
        if podman compose version &>/dev/null; then
            COMPOSE_CMD="podman compose"
        else
            echo "  [WARN] 'podman compose' (Docker Compose Plugin) not found, installing..."
            install_packages docker-compose
            COMPOSE_CMD="podman compose"
        fi
        # Enable Podman API socket for the Docker Compose Plugin
        systemctl --user enable --now podman.socket 2>/dev/null || true
        echo "Runtime: podman (found at $(command -v podman))"
        return 0
    fi
    echo "No container runtime found. Installing Docker..."
    install_packages docker docker-compose docker-buildx
    if command -v docker &>/dev/null; then
        RUNTIME="docker"
        sudo systemctl enable --now docker 2>/dev/null || true
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        echo "  Added $USER to docker group. Re-login if needed."
        if docker info &>/dev/null 2>&1; then
            DOCKER_CMD="docker"
            COMPOSE_CMD="docker compose"
        else
            echo "  Docker socket requires sudo — wrapping with sudo"
            DOCKER_CMD="sudo docker"
            COMPOSE_CMD="sudo docker compose"
        fi
        return 0
    fi
    echo "  [FATAL] Could not install Docker. Install manually: https://docs.docker.com/engine/install/"
    exit 1
}

# ─── Pre-flight: check required tools, create dirs ──────
preflight() {
    local missing=()
    for tool in wget sha256sum; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
        missing+=("python-pip")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing tools: ${missing[*]}. Installing..."
        install_packages "${missing[@]}"
        # special case: ensure pip3 exists after install
        command -v pip3 &>/dev/null || PIP_CMD="pip"
    fi
    command -v pip3 &>/dev/null && PIP_CMD="pip3" || PIP_CMD="pip"

    mkdir -p "$VENDOR_DIR"/{pip/{telecom-api,vosk-worker},vosk,ueransim,docker,checksums,open5gs-webui,logs}
    echo "Vendor directory: $VENDOR_DIR"
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════╗"
echo "║   MVNO Offline Bootstrap                     ║"
echo "╚══════════════════════════════════════════════╝"

detect_os
preflight
detect_runtime

# ─── Step 1: Pull pre-built images ─────────────────────
PREBUILT_IMAGES=(
    "mongo:8.0"
  "drachtio/rtpengine:latest"
  "victoriametrics/victoria-metrics:latest"
  "victoriametrics/vmagent:latest"
  "grafana/grafana-oss:latest"
    "debian:bookworm-slim"
    "python:3.11-alpine"
    "maven:3.9-eclipse-temurin-25"
    "eclipse-temurin:25-jre"
    "alpine:3.19"
    "node:20-alpine"
    "timberio/vector:latest-alpine"
)

for img in "${PREBUILT_IMAGES[@]}"; do
    label="pull:${img//\//_}"
    try_log "$label" "$DOCKER_CMD pull '$img'"
done

# ─── Step 2: Download Maven dependencies ────────────────
try_log "maven:telecom-api" "
    cd '$PROJECT_DIR/telecom-api' &&
    ./mvnw -B dependency:go-offline -Dmaven.repo.local='$VENDOR_DIR/maven/repository'
"
try_log "pip:vosk-worker" "$PIP_CMD download vosk>=0.3.45 soundfile>=0.12.1 numpy>=1.26.0 httpx>=0.27.0 -d '$VENDOR_DIR/pip/vosk-worker/'"

# ─── Step 3: Download Vosk model ────────────────────────
try_log "vosk-model" "wget -q --show-progress -O '$VENDOR_DIR/vosk/vosk-model-small-en-us-0.15.zip' https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

# ─── Step 4: Download UERANSIM source ───────────────────
try_log "ueransim-source" "wget -q --show-progress -O '$VENDOR_DIR/ueransim/UERANSIM-${UERANSIM_VERSION}.tar.gz' 'https://github.com/aligungr/UERANSIM/archive/refs/tags/v${UERANSIM_VERSION}.tar.gz'"

# ─── Step 5: Download & extract Open5GS WebUI source ────
try_log "open5gs-webui-source" "
    mkdir -p '$VENDOR_DIR/open5gs-webui' &&
    wget -q --show-progress -O '$VENDOR_DIR/open5gs-webui/open5gs-${OPEN5GS_VERSION}.tar.gz' 'https://github.com/open5gs/open5gs/archive/refs/tags/v${OPEN5GS_VERSION}.tar.gz' &&
    cd '$VENDOR_DIR/open5gs-webui' &&
    tar xzf 'open5gs-${OPEN5GS_VERSION}.tar.gz' &&
    rm -rf src &&
    mv 'open5gs-${OPEN5GS_VERSION}/webui' src &&
    rm -rf 'open5gs-${OPEN5GS_VERSION}' 'open5gs-${OPEN5GS_VERSION}.tar.gz' &&
    mkdir -p '$OPEN5GS_DIR/webui/src' &&
    cp -r src/* '$OPEN5GS_DIR/webui/src/' &&
    cd '$PROJECT_DIR'
"

# ─── Step 6: Build custom Docker images ─────────────────
try_log "build:compose" "$COMPOSE_CMD -f '$PROJECT_DIR/docker-compose.yml' -f '$PROJECT_DIR/docker-compose.build.yml' build"

# Build images individually (in case compose didn't pick them up)
for build_target in \
    "mvno-open5gs:$OPEN5GS_DIR/Dockerfile:$OPEN5GS_DIR" \
    "mvno-ueransim:$PROJECT_DIR/configs/ueransim/Dockerfile:$PROJECT_DIR" \
    "mvno-open5gs-webui:$OPEN5GS_DIR/webui/Dockerfile:$OPEN5GS_DIR/webui" \
    "mvno-kamailio:$PROJECT_DIR/configs/kamailio/Dockerfile:$PROJECT_DIR"; do
    IFS=':' read -r tag dockerfile ctx <<< "$build_target"
    label="build:${tag}"
    try_log_quiet "$label" "$DOCKER_CMD build -t '${tag}:latest' -f '$dockerfile' '$ctx'"
done

# ─── Step 7: Save all images as tarballs ────────────────
# Tag compose-built images with stable names
for svc in osmo-smsc telecom-api vosk-worker; do
    tag="mvno-${svc}"
    existing=$($DOCKER_CMD images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "^${tag}:|^mvno_${svc}:" | head -1)
    if [ -n "$existing" ]; then
        try_log_quiet "tag:${tag}" "$DOCKER_CMD tag '$existing' '${tag}:latest'"
    fi
done

declare -A SAVE_IMAGES=(
    ["mongo-8.0"]="mongo:8.0"
    ["drachtio-rtpengine-latest"]="drachtio/rtpengine:latest"
    ["mvno-kamailio"]="mvno-kamailio:latest"
    ["victoria-metrics-latest"]="victoriametrics/victoria-metrics:latest"
    ["vmagent-latest"]="victoriametrics/vmagent:latest"
    ["grafana-oss-latest"]="grafana/grafana-oss:latest"
    ["debian-bookworm-slim"]="debian:bookworm-slim"
    ["python-3.11-alpine"]="python:3.11-alpine"
    ["eclipse-temurin-25-jre"]="eclipse-temurin:25-jre"
    ["alpine-3.19"]="alpine:3.19"
    ["node-20-alpine"]="node:20-alpine"
    ["timberio-vector-latest-alpine"]="timberio/vector:latest-alpine"
    ["mvno-osmo-smsc"]="mvno-osmo-smsc:latest"
    ["mvno-telecom-api"]="mvno-telecom-api:latest"
    ["maven-3.9-eclipse-temurin-25"]="maven:3.9-eclipse-temurin-25"
    ["mvno-vosk-worker"]="mvno-vosk-worker:latest"
    ["mvno-open5gs"]="mvno-open5gs:latest"
    ["mvno-ueransim"]="mvno-ueransim:latest"
    ["mvno-open5gs-webui"]="mvno-open5gs-webui:latest"
)

for name in "${!SAVE_IMAGES[@]}"; do
    img="${SAVE_IMAGES[$name]}"
    out="$VENDOR_DIR/docker/${name}.tar"
    label="save:${name}"
    if $DOCKER_CMD image inspect "$img" &>/dev/null 2>&1; then
        try_log_quiet "$label" "$DOCKER_CMD save '$img' -o '$out'"
    else
        echo "  [SKIP] $img not found locally"
    fi
done

# ─── Step 8: Generate checksums ─────────────────────────
try_log "checksums" "find '$VENDOR_DIR' -type f ! -path '*/checksums/*' ! -path '*/logs/*' -exec sha256sum {} \; > '$VENDOR_DIR/checksums/sha256sums.txt'"

# ─── Summary ────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SUMMARY                                      ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Succeeded: ${#SUCCESSES[@]}"
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "  FAILED:    ${#FAILURES[@]}"
    for f in "${FAILURES[@]}"; do echo "    ✗ $f"; done
    echo ""
    echo "  Check logs: $LOG_DIR"
    exit 1
fi
echo "  All downloads completed successfully."
echo ""
echo "  Vendor directory: $VENDOR_DIR"
echo "  Size:            $(du -sh "$VENDOR_DIR" 2>/dev/null | cut -f1)"
echo ""
echo "  Next steps:"
echo "    1. Compress: tar czf mvno-offline.tar.gz vendor/"
echo "    2. Transfer to air-gapped machine"
echo "    3. Run: ./scripts/load-offline.sh"
echo "    4. Start stack: podman compose -f docker-compose.yml up -d"
echo ""
echo "  To build from source (needs internet):"
echo "    podman compose -f docker-compose.yml -f docker-compose.build.yml up -d --build"
