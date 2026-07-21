#!/usr/bin/env bash

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"

# shellcheck source=polybar-ensure.sh
source "${HOME}/.config/polybar/polybar-ensure.sh"

LOCK_FILE="${XDG_RUNTIME_DIR}/polybar.launch.lock"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

expected=$(polybar_expected_count)

if polybar_is_healthy "$expected"; then
    exit 0
fi

if (( $(polybar_running_count) > expected )); then
    polybar_stop_all
fi

if (( $(polybar_running_count) > 0 && $(polybar_running_count) <= expected )); then
    for _ in {1..30}; do
        if polybar_is_healthy "$expected"; then
            exit 0
        fi
        sleep 0.1
    done
fi

polybar_stop_all

mapfile -t monitors < <(polybar --list-monitors 2>/dev/null | cut -d: -f1)
if ((${#monitors[@]} == 0)); then
    monitors=("")
fi

for m in "${monitors[@]}"; do
    if [[ -n "$m" ]]; then
        MONITOR=$m polybar bar1 >>/tmp/polybar1.log 2>&1 &
    else
        polybar bar1 >>/tmp/polybar1.log 2>&1 &
    fi
done

disown

for _ in {1..50}; do
    if polybar_is_healthy "$expected"; then
        exit 0
    fi
    sleep 0.1
done

# Startup failed or left duplicates — reset and let the watchdog retry later.
if (( $(polybar_running_count) != expected )); then
    polybar_stop_all
    exit 1
fi

exit 0
