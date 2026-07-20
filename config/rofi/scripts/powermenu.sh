#!/usr/bin/env bash
#
# Simple powermenu for rofi

rofi_config="${HOME}/.config/rofi/config.rasi"

askAction() {
    optionsAction=(
        " Shut down"
        " Reboot"
        " Suspend"
        " Log out"
        " Lock screen"
    )

    action=$(
        printf '%s\n' "${optionsAction[@]}" |
            rofi -dmenu -i -p " Power" -config "$rofi_config" -location 2 -yoffset 62 -xoffset -20 -width 18
    )
    case "${action}" in
    *"Shut down")
        askConfirm "poweroff"
        ;;
    *"Reboot")
        askConfirm "reboot"
        ;;
    *"Suspend")
        askConfirm "systemctl suspend"
        ;;
    *"Log out")
        askConfirm "awesome-client 'awesome.quit()'"
        ;;
    *"Lock screen")
        askConfirm "${HOME}/.local/bin/lock-screen"
        ;;
    *)
        exit 0
        ;;
    esac
}

askConfirm() {
    confirmOptions=(" Yes" " No")

    confirm=$(
        printf '%s\n' "${confirmOptions[@]}" |
            rofi -dmenu -i -p " Are you sure?" -config "$rofi_config" -location 2 -yoffset 62 -xoffset -20 -width 18
    )

    case "${confirm}" in
    *"Yes")
        eval "$1"
        ;;
    *)
        exit 0
        ;;
    esac
}

### PROGRAM START ###

askAction
