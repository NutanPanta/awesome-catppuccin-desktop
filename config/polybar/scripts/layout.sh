#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"

layout_name=$(
    awesome-client "return require('awful').screen.focused().selected_tag.layout.name" 2>/dev/null \
        | sed -n 's/.*"\([^"]*\)".*/\1/p'
)

case "$layout_name" in
    tile) icon="󰉁" ;;
    floating) icon="󰎈" ;;
    fair) icon="󰔨" ;;
    max) icon="󰊓" ;;
    *) icon="󰕰" ;;
esac

printf '%%{F#cba6f7}%%{T5}%s%%{T-}\n' "$icon"
