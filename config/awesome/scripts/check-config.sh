#!/usr/bin/env bash
# Validate Awesome config before reload (Super+Shift+r).

set -euo pipefail

RC="${1:-$HOME/.config/awesome/rc.lua}"

if ! command -v awesome >/dev/null; then
    echo "awesome: command not found" >&2
    exit 1
fi

echo "Checking $RC ..."
awesome -k "$RC"
echo "OK — safe to reload Awesome."
