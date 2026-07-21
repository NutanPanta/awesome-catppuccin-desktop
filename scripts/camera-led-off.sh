#!/usr/bin/env bash
# Turn off the IPU7 camera LED by restarting the on-demand bridge service.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Restarting ipu7-camera-dynamic (requires sudo)..."
    exec sudo systemctl restart ipu7-camera-dynamic.service
fi

systemctl restart ipu7-camera-dynamic.service
echo "Camera bridge restarted. LED should turn off within a few seconds."
