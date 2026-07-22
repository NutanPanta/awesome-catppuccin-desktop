#!/usr/bin/env bash
# One-shot login check for Intel BE200 ghost hci0 (boot init failure).
# Soft recovery only — no polkit prompt. Full PCI reset runs when you click
# the polybar Bluetooth icon (left or right click).

set -euo pipefail

sleep 10

if bluetoothctl show &>/dev/null; then
    exit 0
fi

export BLUETOOTH_ENSURE_SOFT_ONLY=1
# shellcheck source=/dev/null
source "${HOME}/.config/polybar/scripts/bluetooth-ensure.sh"
ensure_bluetooth || true

if bluetoothctl show &>/dev/null; then
    command -v dunstify &>/dev/null && dunstify "Bluetooth" "Bluetooth adapter recovered after login."
    exit 0
fi

if [[ -e /sys/class/bluetooth/hci0 ]] && [[ ! -r /sys/class/bluetooth/hci0/address ]]; then
    command -v dunstify &>/dev/null && dunstify \
        "Bluetooth" \
        "Adapter stuck after boot. Click the polybar Bluetooth icon once (approve admin prompt)."
fi
