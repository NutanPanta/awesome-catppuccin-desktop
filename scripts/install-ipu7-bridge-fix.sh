#!/usr/bin/env bash
# Install patched ipu7-camera-dynamic bridge (single instance, low CPU).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo bash $0"
    exit 1
fi

install -m 755 "$ROOT/scripts/ipu7-camera-dynamic" /usr/local/sbin/ipu7-camera-dynamic
install -d /etc/systemd/system/ipu7-camera-dynamic.service.d
install -m 644 "$ROOT/config/systemd/ipu7-camera-dynamic.service.d/override.conf" \
    /etc/systemd/system/ipu7-camera-dynamic.service.d/override.conf

# Drop any stray bridge processes before restart.
pkill -f '/usr/local/sbin/ipu7-camera-dynamic' 2>/dev/null || true
rm -f /run/ipu7-camera-dynamic.lock

systemctl daemon-reload
systemctl restart ipu7-camera-dynamic
systemctl --no-pager --full status ipu7-camera-dynamic

echo
echo "Installed. Verify only one process:"
echo "  pgrep -af ipu7-camera-dynamic"
