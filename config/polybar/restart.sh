#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

pkill -x polybar 2>/dev/null || true
pkill -f "polybar-watchdog-loop" 2>/dev/null || true
pkill -f "awesome-polybar-watchdog" 2>/dev/null || true

for _ in {1..30}; do
    pgrep -x polybar >/dev/null || break
    sleep 0.1
done

# Drop stale bar windows that outlive the polybar process.
for wid in $(xdotool search --class polybar 2>/dev/null); do
    [[ -n "$wid" ]] || continue
    xdotool windowkill "$wid" 2>/dev/null || xdotool windowunmap "$wid" 2>/dev/null || true
done

for _ in {1..20}; do
    [[ -z "$(xdotool search --class polybar 2>/dev/null)" ]] && break
    sleep 0.1
done

"$HOME/.config/polybar/launch.sh"
exec "$HOME/.config/polybar/status.sh"
