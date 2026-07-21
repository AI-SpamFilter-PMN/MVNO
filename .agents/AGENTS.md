# Workspace Rules

## Core Directives
* **Lightweight Footprint**: Always prioritize lightweight, low-resource solutions. Avoid heavy JVM-based or bloated frameworks when simpler, compiled, or single-binary alternatives exist (e.g., VictoriaMetrics instead of Prometheus, C/Go/Rust-based components).
* **Optimization First**: Design for high performance, low RAM/CPU utilization, and minimal disk write overhead.
* **Component Selection**: Favor single-binary deployments and low-footprint scraping agents (like `vmagent`) to keep the system resource-efficient.

## Deployment Guidelines
* **Dual Deployment Methods**: Ensure all components can be built and run either **natively** (via installation scripts, systemd units) or **containerized**.
* **Container Engine Agnosticism (Podman & Docker)**: 
  - Write standard `docker-compose.yml` configurations compatible with both `docker compose` and `podman compose`.
  - Design for **rootless container execution** (default in Podman): avoid using privileged ports (use ports > 1024 internally, or map them externally), and avoid mounting `/var/run/docker.sock`.
  - Ensure volume mount compatibility (e.g., use relative paths, and prepare for SELinux context labeling using the `:z` flag if volume mounts are used).

