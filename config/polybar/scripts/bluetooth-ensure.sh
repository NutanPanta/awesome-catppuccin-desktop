#!/usr/bin/env bash
# Bring Bluetooth up when the controller is missing or powered off.

notify() {
    command -v dunstify &>/dev/null && dunstify "$1" "$2"
}

controller_ready() {
    bluetoothctl show &>/dev/null
}

controller_powered() {
    controller_ready && bluetoothctl show 2>/dev/null | grep -q "Powered: yes"
}

unblock_bluetooth() {
    command -v rfkill &>/dev/null || return 0

    rfkill unblock bluetooth 2>/dev/null || true

    local block
    block=$(rfkill list bluetooth 2>/dev/null) || return 0
    while IFS= read -r idx; do
        rfkill unblock "$idx" 2>/dev/null || true
    done < <(awk '/^[0-9]+:/{print $1}' <<< "$block" | tr -d ':')
}

run_root() {
    if "$@" 2>/dev/null; then
        return 0
    fi

    command -v pkexec &>/dev/null || return 1
    pkexec "$@" 2>/dev/null
}

start_bluetooth_service() {
    systemctl is-active --quiet bluetooth 2>/dev/null && return 0

    notify "Bluetooth" "Starting Bluetooth service…"
    run_root systemctl start bluetooth || return 1
    sleep 2
}

restart_bluetooth_service() {
    notify "Bluetooth" "Restarting Bluetooth…"
    run_root systemctl restart bluetooth || return 1
    sleep 2
}

reload_bluetooth_modules() {
    lsmod | grep -qE '^(btintel_pcie|btintel|bluetooth)\b' || return 1

    notify "Bluetooth" "Reloading Bluetooth driver…"
    run_root bash -c '
        modprobe -r btintel_pcie btintel 2>/dev/null || true
        modprobe btintel_pcie 2>/dev/null || modprobe btintel 2>/dev/null || modprobe bluetooth
        systemctl restart bluetooth
    ' || return 1
    sleep 3
}

power_on_controller() {
    bluetoothctl power on 2>/dev/null || true
    sleep 1
}

ensure_bluetooth() {
    unblock_bluetooth

    if controller_powered; then
        return 0
    fi

    if controller_ready; then
        power_on_controller
        controller_powered && return 0
    fi

    start_bluetooth_service || true
    unblock_bluetooth

    if controller_ready; then
        power_on_controller
        controller_powered && return 0
    fi

    restart_bluetooth_service || true
    unblock_bluetooth

    if controller_ready; then
        power_on_controller
        if controller_powered; then
            notify "Bluetooth" "Bluetooth recovered."
            return 0
        fi
    fi

    reload_bluetooth_modules || true
    unblock_bluetooth
    power_on_controller

    if controller_powered; then
        notify "Bluetooth" "Bluetooth recovered."
        return 0
    fi

    notify "Bluetooth" "Could not enable Bluetooth. Reboot if this keeps happening."
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_bluetooth
fi
