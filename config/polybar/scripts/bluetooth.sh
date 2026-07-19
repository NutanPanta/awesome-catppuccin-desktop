#!/usr/bin/env bash

powered=$(bluetoothctl show 2>/dev/null | awk -F': ' '/Powered/{print $2}')
if [[ "$powered" != "yes" ]]; then
    echo "%{F#6c7086}%{T6}󰂲"
    exit 0
fi

if bluetoothctl devices Connected 2>/dev/null | grep -q .; then
    echo "%{F#89b4fa}%{T6}󰂱"
else
    echo "%{F#89b4fa}%{T6}󰂯"
fi
