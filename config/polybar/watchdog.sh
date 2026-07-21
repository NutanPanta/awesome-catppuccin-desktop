#!/usr/bin/env bash
# polybar-watchdog-loop — single recovery loop; do not start more than one copy.

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# shellcheck source=polybar-ensure.sh
source "${HOME}/.config/polybar/polybar-ensure.sh"

LOCK_FILE="${XDG_RUNTIME_DIR}/polybar.watchdog.lock"
LAUNCH_SCRIPT="${HOME}/.config/polybar/launch.sh"
COOLDOWN_SECS="${POLYBAR_LAUNCH_COOLDOWN:-60}"

exec 8>"$LOCK_FILE"
if ! flock -n 8; then
    exit 0
fi

last_launch=0

while sleep 30; do
    [[ -x "$LAUNCH_SCRIPT" ]] || continue

    expected=$(polybar_expected_count)

    if polybar_is_healthy "$expected"; then
        continue
    fi

    now=$(date +%s)
    if (( now - last_launch < COOLDOWN_SECS )); then
        continue
    fi

    "$LAUNCH_SCRIPT"
    last_launch=$now
done
