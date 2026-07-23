#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

source "$HOME/.config/polybar/scripts/volume-lib.sh"

pkill -u "$USER" -f "volume-slider.py" 2>/dev/null || true

if ! volume_get_state &>/dev/null; then
    command -v dunstify &>/dev/null && dunstify "Volume" "Audio is unavailable."
    exit 1
fi

awesome-client "require('volume-slider').toggle()" >/dev/null 2>&1
