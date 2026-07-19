#!/usr/bin/env bash

if nmcli -t -f TYPE,STATE dev status 2>/dev/null | grep -q '^ethernet:connected'; then
    echo "%{F#b4befe}%{T1}󰈀 %{T0}Wired"
    exit 0
fi

wifi_line=$(nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi 2>/dev/null | grep '^yes' | head -1)

if [[ -z "$wifi_line" ]]; then
    if nmcli radio wifi 2>/dev/null | grep -q 'enabled'; then
        echo "%{F#6c7086}%{T1}󰤭 %{T0}Disconnected"
    else
        echo "%{F#6c7086}%{T1}󰤮 %{T0}WiFi off"
    fi
    exit 0
fi

signal=$(echo "$wifi_line" | cut -d: -f3)
ssid=$(echo "$wifi_line" | cut -d: -f2)

if [[ "$signal" -ge 80 ]]; then
    icon="󰤨"
elif [[ "$signal" -ge 60 ]]; then
    icon="󰤥"
elif [[ "$signal" -ge 40 ]]; then
    icon="󰤢"
else
    icon="󰤟"
fi

if [[ ${#ssid} -gt 12 ]]; then
    ssid="${ssid:0:11}…"
fi

echo "%{F#b4befe}%{T1}${icon} %{T0}${ssid}"
