#!/usr/bin/env bash
set -euo pipefail

"${HOME}/.config/polybar/scripts/bluetooth-ensure.sh"
bluetoothctl power toggle
