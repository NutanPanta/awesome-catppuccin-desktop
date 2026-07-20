#!/usr/bin/env bash

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"
LOCK_FILE="${XDG_RUNTIME_DIR}/polybar.launch.lock"

cleanup_polybar_windows() {
    local wid pid
    for wid in $(xdotool search --class polybar 2>/dev/null); do
        [[ -n "$wid" ]] || continue
        pid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            xdotool windowkill "$wid" 2>/dev/null || xdotool windowunmap "$wid" 2>/dev/null || true
            continue
        fi
        if [[ "$pid" != "$(pgrep -x polybar 2>/dev/null | head -1)" ]]; then
            kill "$pid" 2>/dev/null || true
            xdotool windowkill "$wid" 2>/dev/null || true
        fi
    done

    for _ in {1..20}; do
        [[ -z "$(xdotool search --class polybar 2>/dev/null)" ]] && break
        sleep 0.1
    done
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

mapfile -t monitors < <(polybar --list-monitors 2>/dev/null | cut -d: -f1)
if ((${#monitors[@]} == 0)); then
    monitors=("")
fi

running=$(pgrep -u "${USER}" -x polybar 2>/dev/null | wc -l)
window_count=$(xdotool search --class polybar 2>/dev/null | wc -l)

if (( running == ${#monitors[@]} && window_count == ${#monitors[@]} )); then
    exit 0
fi

pkill -x polybar 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x polybar >/dev/null || break
    sleep 0.1
done

cleanup_polybar_windows

for m in "${monitors[@]}"; do
    if [[ -n "$m" ]]; then
        MONITOR=$m polybar bar1 2>&1 | tee -a /tmp/polybar1.log &
    else
        polybar bar1 2>&1 | tee -a /tmp/polybar1.log &
    fi
done

disown

expected=${#monitors[@]}
for _ in {1..50}; do
    running=$(pgrep -u "${USER}" -x polybar 2>/dev/null | wc -l)
    window_count=$(xdotool search --class polybar 2>/dev/null | wc -l)
    if (( running >= expected && window_count >= expected )); then
        break
    fi
    sleep 0.1
done
