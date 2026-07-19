#!/usr/bin/env bash

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

pkill polybar 2>/dev/null
sleep 0.3

mapfile -t monitors < <(polybar --list-monitors | cut -d: -f1)
if ((${#monitors[@]} == 0)); then
    monitors=("")
fi

for m in "${monitors[@]}"; do
    if [[ -n "$m" ]]; then
        MONITOR=$m polybar bar1 2>&1 | tee -a /tmp/polybar1.log &
    else
        polybar bar1 2>&1 | tee -a /tmp/polybar1.log &
    fi
done

disown
