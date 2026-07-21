#!/bin/bash
set -euo pipefail

run_once() {
    local pattern=$1
    shift
    if pgrep -u "$USER" -f "$pattern" >/dev/null 2>&1; then
        return 0
    fi
    "$@" &
}

SCREEN_BLANK_MINUTES=15
SCREEN_LOCK_COMMAND="${HOME}/.local/bin/lock-screen"

set_xfconf_int() {
    local prop=$1
    local val=$2
    if xfconf-query -c xfce4-power-manager -p "$prop" -l &>/dev/null; then
        xfconf-query -c xfce4-power-manager -p "$prop" -s "$val"
    else
        xfconf-query -c xfce4-power-manager -p "$prop" -n -t int -s "$val"
    fi
}

set_xfconf_bool() {
    local prop=$1
    local val=$2
    if xfconf-query -c xfce4-power-manager -p "$prop" -l &>/dev/null; then
        xfconf-query -c xfce4-power-manager -p "$prop" -s "$val"
    else
        xfconf-query -c xfce4-power-manager -p "$prop" -n -t bool -s "$val"
    fi
}

set_xfconf_string() {
    local channel=$1
    local prop=$2
    local val=$3
    if xfconf-query -c "$channel" -p "$prop" -l &>/dev/null; then
        xfconf-query -c "$channel" -p "$prop" -s "$val"
    else
        xfconf-query -c "$channel" -p "$prop" -n -t string -s "$val"
    fi
}

configure_screen_lock() {
    if command -v xfconf-query &>/dev/null \
        && command -v "$SCREEN_LOCK_COMMAND" &>/dev/null; then
        set_xfconf_string "xfce4-session" "/general/LockCommand" "$SCREEN_LOCK_COMMAND"
    fi
}

configure_screen_power() {
    local minutes=$SCREEN_BLANK_MINUTES
    local seconds=$((minutes * 60))

    if command -v xfconf-query &>/dev/null; then
        set_xfconf_bool "/xfce4-power-manager/dpms-enabled" "true"
        set_xfconf_int "/xfce4-power-manager/blank-on-ac" "$minutes"
        set_xfconf_int "/xfce4-power-manager/blank-on-battery" "$minutes"
        set_xfconf_int "/xfce4-power-manager/dpms-on-ac-sleep" "$minutes"
        set_xfconf_int "/xfce4-power-manager/dpms-on-battery-sleep" "$minutes"
        set_xfconf_int "/xfce4-power-manager/dpms-on-ac-off" "0"
        set_xfconf_int "/xfce4-power-manager/dpms-on-battery-off" "0"
        set_xfconf_int "/xfce4-power-manager/inactivity-on-ac" "0"
        set_xfconf_int "/xfce4-power-manager/inactivity-on-battery" "0"
    fi

    if command -v xset &>/dev/null; then
        xset s off
        xset s noblank
        xset dpms "$seconds" "$seconds" "$seconds"
        xset +dpms
    fi
}

configure_screen_power
configure_screen_lock

run_once "polkit-gnome-authentication-agent" \
    /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

if command -v touchegg &>/dev/null; then
    pkill -u "$USER" -x touchegg 2>/dev/null || true
    run_once "touchegg --daemon" touchegg --daemon
fi

if command -v picom &>/dev/null; then
    pkill picom 2>/dev/null || true
    sleep 0.5
    picom --config "$HOME/.config/picom/picom.conf" -b
fi

if [[ -x "$HOME/.fehbg" ]]; then
    "$HOME/.fehbg" &
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# Keep a single polybar instance and watchdog across Awesome reloads.
if [[ -r "$HOME/.config/polybar/polybar-ensure.sh" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.config/polybar/polybar-ensure.sh"
    polybar_cleanup_legacy_watchdogs
    polybar_cleanup_excess || true

    if ! polybar_is_healthy "$(polybar_expected_count)" \
        && [[ -x "$HOME/.config/polybar/launch.sh" ]]; then
        "$HOME/.config/polybar/launch.sh"
    fi
elif [[ -x "$HOME/.config/polybar/launch.sh" ]] \
    && ! pgrep -u "$USER" -x polybar >/dev/null; then
    "$HOME/.config/polybar/launch.sh"
fi

run_once "polybar/watchdog.sh" "$HOME/.config/polybar/watchdog.sh"

# Bridge modern StatusNotifier tray icons into Awesome's XEmbed systray.
if command -v snixembed &>/dev/null; then
    pkill -u "$USER" -x snixembed 2>/dev/null || true
    GDK_BACKEND=x11 snixembed --fork
else
    command -v dunstify &>/dev/null && dunstify "Desktop" "Install snixembed for tray app menus: sudo pacman -S snixembed"
fi

if command -v systemctl &>/dev/null; then
    systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
    systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
    for _ in {1..15}; do
        command -v wpctl &>/dev/null && wpctl status &>/dev/null && break
        sleep 0.2
    done
fi

# Single top polybar — apps/taskbar in the center section.
pkill -u "$USER" -x plank 2>/dev/null || true

# WiFi / volume / bluetooth live in polybar — no duplicate tray applets
pkill -u "$USER" -x nm-applet 2>/dev/null || true
pkill -u "$USER" -x pasystray 2>/dev/null || true
pkill -u "$USER" -x blueman-applet 2>/dev/null || true
pkill -u "$USER" -f "blueman-tray" 2>/dev/null || true

run_once "xfce4-power-manager" xfce4-power-manager
configure_screen_power
configure_screen_lock

if command -v dunst &>/dev/null; then
    if pgrep -u "$USER" -x dunst >/dev/null 2>&1; then
        dunstctl reload 2>/dev/null || true
    else
        dunst &
    fi
fi

export GTK_THEME=Catppuccin-Mocha-Standard-Mauve-Dark
export XDG_CURRENT_DESKTOP=awesome

if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface gtk-theme 'catppuccin-mocha-mauve-standard+default' 2>/dev/null || \
    gsettings set org.gnome.desktop.interface gtk-theme 'Catppuccin-Mocha-Standard-Mauve-Dark' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark' 2>/dev/null || true
fi
