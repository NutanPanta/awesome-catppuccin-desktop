#!/usr/bin/env bash

source "$HOME/.config/polybar/scripts/volume-lib.sh"

dir=${1:-up}
step=${2:-5}

case "$dir" in
    up|+) volume_set_step "+" "$step" ;;
    down|-) volume_set_step "-" "$step" ;;
    *) exit 1 ;;
esac

state=$(volume_get_state) || exit 0
read -r muted pct <<< "$state"
volume_notify "$muted" "$pct"
volume_polybar_refresh
