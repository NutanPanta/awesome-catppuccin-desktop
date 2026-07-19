#!/usr/bin/env bash

source "$HOME/.config/polybar/scripts/volume-lib.sh"

volume_toggle_mute

state=$(volume_get_state) || exit 0
read -r muted pct <<< "$state"
volume_notify "$muted" "$pct"
volume_polybar_refresh
