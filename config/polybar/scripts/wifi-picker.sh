#!/usr/bin/env bash

notify() {
    command -v dunstify &>/dev/null && dunstify "$1" "$2"
}

wifi_dev=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
if [[ -z "$wifi_dev" ]]; then
    notify "WiFi" "No wireless device found."
    exit 1
fi

if ! nmcli radio wifi 2>/dev/null | grep -q enabled; then
    nmcli radio wifi on
    sleep 1
fi

nmcli device wifi rescan ifname "$wifi_dev" 2>/dev/null
sleep 0.5

mapfile -t entries < <(
    nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list ifname "$wifi_dev" 2>/dev/null |
        awk -F: '$2 != "" && $2 != "--" {
            mark = ($1 == "*") ? "● " : "  "
            printf "%s%s (%s%%)\n", mark, $2, $3
        }'
)

if ((${#entries[@]} == 0)); then
    notify "WiFi" "No networks found."
    exit 0
fi

options=("  Disconnect")
options+=("${entries[@]}")

chosen=$(
    printf '%s\n' "${options[@]}" |
        rofi -dmenu -i -p "󰤨  WiFi" -config "$HOME/.config/rofi/config.rasi"
)

[[ -z "$chosen" ]] && exit 0

if [[ "$chosen" == *"Disconnect"* ]]; then
    nmcli device disconnect "$wifi_dev"
    notify "WiFi" "Disconnected."
    exit 0
fi

ssid=$(sed -E 's/^(● |  )//; s/ \([0-9]+%\)$//' <<< "$chosen")

if nmcli -t -f NAME connection show --active | grep -Fxq "$ssid"; then
    exit 0
fi

if nmcli device wifi connect "$ssid" ifname "$wifi_dev"; then
    notify "WiFi" "Connected to $ssid"
else
    notify "WiFi" "Failed to connect to $ssid"
fi
