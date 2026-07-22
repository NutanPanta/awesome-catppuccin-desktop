#!/usr/bin/env bash
# Bring Bluetooth up when the controller is missing or powered off.
#
# Recovery order (only when needed):
#   1. rfkill / ThinkPad radio / power on
#   2. Ghost hci0: sysfs reset + bluetoothd restart
#   3. Intel PCIe BT: module reload
#   4. Intel PCIe BT ghost/error: PCI remove + rescan (fixes BE200 cnvi boot failures)
#
# Set BLUETOOTH_ENSURE_SOFT_ONLY=1 to skip step 4 (used at login — avoids a polkit prompt).

notify() {
    command -v dunstify &>/dev/null && dunstify "$1" "$2"
}

controller_ready() {
    bluetoothctl show &>/dev/null
}

controller_powered() {
    controller_ready && bluetoothctl show 2>/dev/null | grep -q "Powered: yes"
}

ghost_hci_present() {
    [[ -e /sys/class/bluetooth/hci0 ]] || return 1
    [[ -r /sys/class/bluetooth/hci0/address ]] && return 1
    return 0
}

intel_pcie_bt_slot() {
    local dev uevent slot

    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/uevent" ]] || continue
        uevent=$(<"$dev/uevent")
        if grep -q 'DRIVER=btintel_pcie' <<< "$uevent"; then
            slot=${dev##*/}
            echo "$slot"
            return 0
        fi
    done

    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/class" && -r "$dev/vendor" ]] || continue
        [[ "$(<"$dev/class")" == "0x0d1100" ]] || continue
        [[ "$(<"$dev/vendor")" == "0x8086" ]] || continue
        slot=${dev##*/}
        echo "$slot"
        return 0
    done

    return 1
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

enable_thinkpad_bluetooth() {
    [[ -r /proc/acpi/ibm/bluetooth ]] || return 0
    grep -q '^status:[[:space:]]*enabled' /proc/acpi/ibm/bluetooth && return 0

    notify "Bluetooth" "Enabling ThinkPad Bluetooth radio…"
    run_root bash -c 'echo enable > /proc/acpi/ibm/bluetooth' || return 1
    sleep 1
}

reset_hci_controller() {
    [[ -w /sys/class/bluetooth/hci0/reset ]] && {
        notify "Bluetooth" "Resetting Bluetooth adapter…"
        echo 1 > /sys/class/bluetooth/hci0/reset 2>/dev/null && sleep 2 && return 0
    }

    [[ -e /sys/class/bluetooth/hci0/reset ]] || return 1

    notify "Bluetooth" "Resetting Bluetooth adapter…"
    run_root bash -c 'echo 1 > /sys/class/bluetooth/hci0/reset' || return 1
    sleep 2
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

    notify "Bluetooth" "Reloading Intel Bluetooth driver…"
    run_root bash -c '
        systemctl stop bluetooth
        modprobe -r btintel_pcie btintel 2>/dev/null || true
        modprobe btintel_pcie 2>/dev/null || modprobe btintel 2>/dev/null || modprobe bluetooth
        systemctl start bluetooth
    ' || return 1
    sleep 3
}

pci_rescan_intel_bluetooth() {
    local slot
    slot=$(intel_pcie_bt_slot) || return 1

    notify "Bluetooth" "Resetting Intel Bluetooth hardware…"
    run_root bash -c "
        set -e
        systemctl stop bluetooth
        modprobe -r btintel_pcie btintel 2>/dev/null || true
        echo 1 > /sys/bus/pci/devices/${slot}/remove
        sleep 1
        echo 1 > /sys/bus/pci/rescan
        sleep 2
        modprobe btintel_pcie
        sleep 2
        systemctl start bluetooth
    " || return 1
    sleep 2
}

power_on_controller() {
    bluetoothctl power on 2>/dev/null || true
    sleep 1
}

recover_ghost_hci() {
    ghost_hci_present || return 1

    enable_thinkpad_bluetooth || true
    reset_hci_controller || true
    restart_bluetooth_service || true
    unblock_bluetooth
    power_on_controller
    controller_powered && return 0

    reload_bluetooth_modules || true
    unblock_bluetooth
    power_on_controller
    controller_powered && return 0
    ! ghost_hci_present && controller_ready && return 0

    if [[ "${BLUETOOTH_ENSURE_SOFT_ONLY:-0}" == 1 ]]; then
        return 1
    fi

    intel_pcie_bt_slot &>/dev/null || return 1
    pci_rescan_intel_bluetooth || return 1
    unblock_bluetooth
    power_on_controller

    controller_powered || controller_ready
}

ensure_bluetooth() {
    unblock_bluetooth
    enable_thinkpad_bluetooth || true

    if controller_powered; then
        return 0
    fi

    if controller_ready; then
        power_on_controller
        controller_powered && return 0
    fi

    if recover_ghost_hci; then
        notify "Bluetooth" "Bluetooth recovered."
        return 0
    fi

    start_bluetooth_service || true
    unblock_bluetooth

    if controller_ready; then
        power_on_controller
        controller_powered && return 0
    fi

    if recover_ghost_hci; then
        notify "Bluetooth" "Bluetooth recovered."
        return 0
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

    if recover_ghost_hci; then
        notify "Bluetooth" "Bluetooth recovered."
        return 0
    fi

    reload_bluetooth_modules || true
    unblock_bluetooth
    power_on_controller

    if controller_powered; then
        notify "Bluetooth" "Bluetooth recovered."
        return 0
    fi

    if ghost_hci_present && [[ "${BLUETOOTH_ENSURE_SOFT_ONLY:-0}" != 1 ]]; then
        if pci_rescan_intel_bluetooth; then
            unblock_bluetooth
            power_on_controller
            if controller_powered; then
                notify "Bluetooth" "Bluetooth recovered."
                return 0
            fi
        fi
    fi

    if ghost_hci_present; then
        notify "Bluetooth" "Bluetooth adapter is stuck. Click the bar icon again and approve the admin prompt."
    else
        notify "Bluetooth" "Bluetooth adapter failed to start. Try: sudo bash ~/.config/polybar/scripts/bluetooth-ensure.sh"
    fi
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_bluetooth
fi
