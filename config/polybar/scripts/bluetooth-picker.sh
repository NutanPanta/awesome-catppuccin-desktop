#!/usr/bin/env bash

notify() {
    command -v dunstify &>/dev/null && dunstify "$1" "$2"
}

rofi_config="$HOME/.config/rofi/config.rasi"

if ! bluetoothctl show &>/dev/null; then
    notify "Bluetooth" "Bluetooth service unavailable."
    exit 1
fi

if ! bluetoothctl show | grep -q "Powered: yes"; then
    bluetoothctl power on
    sleep 1
fi

declare -A device_macs=()
options=()

while IFS= read -r line; do
    mac=$(awk '{print $2}' <<< "$line")
    name=$(cut -d' ' -f3- <<< "$line")
    [[ -z "$mac" || -z "$name" ]] && continue

    device_macs["$name"]=$mac
    if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
        options+=("● $name")
    else
        options+=("  $name")
    fi
done < <(bluetoothctl devices Paired 2>/dev/null)

options+=("  Scan for new devices")
options+=("  Disconnect all")
options+=("  Power off Bluetooth")

chosen=$(
    printf '%s\n' "${options[@]}" |
        rofi -dmenu -i -p "󰂯  Bluetooth" -config "$rofi_config"
)

[[ -z "$chosen" ]] && exit 0

case "$chosen" in
    *"Scan for new devices"*)
        notify "Bluetooth" "Scanning for devices…"
        bluetoothctl scan on &>/dev/null &
        scan_pid=$!
        sleep 5
        bluetoothctl scan off &>/dev/null
        wait "$scan_pid" 2>/dev/null || true

        declare -A scan_macs=()
        scan_opts=()

        while IFS= read -r line; do
            mac=$(awk '{print $2}' <<< "$line")
            name=$(cut -d' ' -f3- <<< "$line")
            [[ -z "$mac" || -z "$name" ]] && continue
            bluetoothctl info "$mac" 2>/dev/null | grep -q "Paired: yes" && continue
            scan_macs["$name"]=$mac
            scan_opts+=("+ $name")
        done < <(bluetoothctl devices 2>/dev/null)

        if ((${#scan_opts[@]} == 0)); then
            notify "Bluetooth" "No new devices found."
            exit 0
        fi

        pick=$(
            printf '%s\n' "${scan_opts[@]}" |
                rofi -dmenu -i -p "󰂯  Pair device" -config "$rofi_config"
        )
        [[ -z "$pick" ]] && exit 0

        name=${pick#+ }
        mac=${scan_macs[$name]}
        bluetoothctl pair "$mac" && bluetoothctl trust "$mac" && bluetoothctl connect "$mac"
        notify "Bluetooth" "Paired with $name"
        ;;
    *"Disconnect all"*)
        while IFS= read -r line; do
            mac=$(awk '{print $2}' <<< "$line")
            bluetoothctl disconnect "$mac" 2>/dev/null
        done < <(bluetoothctl devices Connected 2>/dev/null)
        notify "Bluetooth" "Disconnected all devices."
        ;;
    *"Power off Bluetooth"*)
        bluetoothctl power off
        notify "Bluetooth" "Bluetooth turned off."
        ;;
    *)
        name=$(sed -E 's/^(● |  )//' <<< "$chosen")
        mac=${device_macs[$name]}

        if [[ -z "$mac" ]]; then
            notify "Bluetooth" "Device not found."
            exit 1
        fi

        if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
            bluetoothctl disconnect "$mac"
            notify "Bluetooth" "Disconnected from $name"
        elif bluetoothctl connect "$mac"; then
            notify "Bluetooth" "Connected to $name"
        else
            notify "Bluetooth" "Failed to connect to $name"
        fi
        ;;
esac
