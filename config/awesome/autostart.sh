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

xset s off
xset -dpms
xset s noblank

run_once "polkit-gnome-authentication-agent" \
    /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

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

if command -v systemctl &>/dev/null; then
    systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
    systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
    for _ in {1..15}; do
        command -v wpctl &>/dev/null && wpctl status &>/dev/null && break
        sleep 0.2
    done
fi

if [[ -x "$HOME/.config/polybar/launch.sh" ]]; then
    "$HOME/.config/polybar/launch.sh"
fi

# Single top polybar — apps/taskbar in the center section.
pkill -u "$USER" -x plank 2>/dev/null || true

# WiFi / volume / bluetooth live in polybar — no duplicate tray applets
pkill -u "$USER" -x nm-applet 2>/dev/null || true
pkill -u "$USER" -x pasystray 2>/dev/null || true
pkill -u "$USER" -x blueman-applet 2>/dev/null || true
pkill -u "$USER" -f "blueman-tray" 2>/dev/null || true

run_once "xfce4-power-manager" xfce4-power-manager

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
