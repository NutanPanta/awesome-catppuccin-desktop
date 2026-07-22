#!/usr/bin/env bash
# Shared helpers to keep exactly one polybar instance per monitor.

polybar_expected_count() {
    local count
    count=$(polybar --list-monitors 2>/dev/null | wc -l)
    (( count == 0 )) && count=1
    echo "$count"
}

polybar_running_count() {
    local count
    count=$(pgrep -c -u "${USER}" -x polybar 2>/dev/null) || true
    count=${count:-0}
    echo "$count"
}

polybar_window_count() {
    local count
    count=$(xdotool search --class polybar 2>/dev/null | wc -l | tr -d '[:space:]')
    count=${count:-0}
    echo "$count"
}

polybar_cleanup_windows() {
    local wid pid keep_pid
    keep_pid=$(pgrep -u "${USER}" -x polybar 2>/dev/null | head -1)

    for wid in $(xdotool search --class polybar 2>/dev/null); do
        [[ -n "$wid" ]] || continue
        pid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            xdotool windowkill "$wid" 2>/dev/null || xdotool windowunmap "$wid" 2>/dev/null || true
            continue
        fi
        if [[ -n "$keep_pid" && "$pid" != "$keep_pid" ]]; then
            kill "$pid" 2>/dev/null || true
            xdotool windowkill "$wid" 2>/dev/null || true
        fi
    done

    for _ in {1..20}; do
        [[ -z "$(xdotool search --class polybar 2>/dev/null)" ]] && break
        sleep 0.1
    done
}

polybar_stop_all() {
    pkill -u "${USER}" -x polybar 2>/dev/null || true
    for _ in {1..30}; do
        pgrep -u "${USER}" -x polybar >/dev/null || break
        sleep 0.1
    done
    polybar_cleanup_windows
}

polybar_is_healthy() {
    local expected=${1:-$(polybar_expected_count)}
    local running windows
    running=$(polybar_running_count)
    windows=$(polybar_window_count)
    (( running == expected && windows == expected ))
}

polybar_cleanup_excess() {
    local expected=${1:-$(polybar_expected_count)}
    local running windows
    running=$(polybar_running_count)
    windows=$(polybar_window_count)

    if polybar_is_healthy "$expected"; then
        return 0
    fi

    if (( running > expected || windows > expected )); then
        polybar_stop_all
        return 1
    fi

    return 1
}

polybar_cleanup_legacy_watchdogs() {
    pkill -u "${USER}" -f "polybar-watchdog-loop" 2>/dev/null || true
    pkill -u "${USER}" -f "awesome-polybar-watchdog" 2>/dev/null || true

    local watchdog_count
    watchdog_count=$(pgrep -u "${USER}" -fc "[p]olybar/watchdog.sh" 2>/dev/null) || true
    watchdog_count=${watchdog_count:-0}
    while (( watchdog_count > 1 )); do
        pkill -u "${USER}" -f "polybar/watchdog.sh" 2>/dev/null || true
        sleep 0.2
        watchdog_count=$(pgrep -u "${USER}" -fc "[p]olybar/watchdog.sh" 2>/dev/null) || true
        watchdog_count=${watchdog_count:-0}
    done
}

polybar_start_watchdog() {
    local script="${HOME}/.config/polybar/watchdog.sh"
    [[ -x "$script" ]] || return 0
    pgrep -u "${USER}" -f "[p]olybar/watchdog.sh" >/dev/null 2>&1 && return 0
    "$script" &
    disown
}
