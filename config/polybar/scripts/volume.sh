#!/usr/bin/env bash

source "$HOME/.config/polybar/scripts/volume-lib.sh"

state=$(volume_get_state) || {
    echo "%{F#6c7086}%{T1}󰝟 %{T0}--"
    exit 0
}

read -r muted pct <<< "$state"
icon=$(volume_icon "$pct" "$muted")

if [[ "$muted" == "yes" || "$muted" == "1" ]]; then
    echo "%{F#6c7086}%{T1}${icon} %{T0}muted"
    exit 0
fi

echo "%{F#89dceb}%{T1}${icon} %{T0}${pct}%"
