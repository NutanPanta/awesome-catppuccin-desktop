#!/usr/bin/env bash
# Disable heavy dev services at boot. Re-enable individually when needed:
#   sudo systemctl enable --now <service>

set -euo pipefail

SERVICES=(
    mongodb
    docker
    docker.socket
    containerd
    ollama
    valkey
    proton.VPN
)

for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        systemctl disable --now "$svc.service"
        echo "Disabled: $svc"
    else
        echo "Skip (not installed): $svc"
    fi
done

echo
echo "Still enabled at boot:"
systemctl is-enabled bluetooth postgresql ipu7-camera-dynamic 2>/dev/null || true
