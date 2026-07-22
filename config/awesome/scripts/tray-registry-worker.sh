#!/usr/bin/env bash
set -euo pipefail

CACHE_PATH="${1:?cache path required}"
MODE="${2:-full}"
HOME="${HOME:-$HOME}"
AWESOME_CFG="${HOME}/.config/awesome"
WORKER="${AWESOME_CFG}/scripts/tray-registry-worker.lua"

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

mkdir -p "$(dirname "$CACHE_PATH")"
TMP="${CACHE_PATH}.tmp.$$"

lua "$WORKER" "$TMP" "$MODE"
mv "$TMP" "$CACHE_PATH"
