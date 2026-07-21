#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# shellcheck source=polybar-ensure.sh
source "${HOME}/.config/polybar/polybar-ensure.sh"

polybar_cleanup_legacy_watchdogs
polybar_stop_all

"$HOME/.config/polybar/launch.sh"
polybar_start_watchdog

exec "$HOME/.config/polybar/status.sh"
