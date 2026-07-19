#!/usr/bin/env bash
# Diagnose and repair PipeWire audio on this machine.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }

if [[ "${EUID:-$(id -u)}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
    error "Run as your normal user, not root: bash ~/.config/awesome/fix-audio.sh"
    exit 1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

LIBCAMERA_DROPIN=/etc/pipewire/pipewire.conf.d/50-libcamera.conf
LIBCAMERA_DISABLED=/etc/pipewire/pipewire.conf.d/50-libcamera.conf.disabled

info "Checking PipeWire services..."
if ! systemctl --user is-active pipewire wireplumber pipewire-pulse &>/dev/null; then
    warn "PipeWire services are not all active yet."
fi

if [[ -f "$LIBCAMERA_DROPIN" ]]; then
    warn "Found global libcamera PipeWire module (this often breaks all audio)."
    info "Disabling $LIBCAMERA_DROPIN (sudo required)..."
    sudo mv "$LIBCAMERA_DROPIN" "$LIBCAMERA_DISABLED"
    info "Disabled libcamera PipeWire drop-in."
elif [[ -f "$LIBCAMERA_DISABLED" ]]; then
    info "Libcamera PipeWire drop-in is already disabled."
fi

mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
cat > "$HOME/.config/wireplumber/wireplumber.conf.d/10-libcamera.conf" << 'EOF'
wireplumber.profiles = {
  main = {
    monitor.libcamera = disabled
  }
}
EOF

info "Enabling and restarting PipeWire..."
systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl --user restart pipewire wireplumber pipewire-pulse

for _ in {1..20}; do
    if wpctl status &>/dev/null; then
        break
    fi
    sleep 0.2
done

if ! wpctl status &>/dev/null; then
    error "PipeWire still is not responding."
    echo
    echo "Recent logs:"
    journalctl --user -u pipewire -u wireplumber -u pipewire-pulse -b --no-pager | tail -30
    exit 1
fi

info "Current audio devices:"
wpctl status | sed -n '/Audio/,/Video/p'

DEFAULT_SINK=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk -F"'" '/node.name/ {print $2; exit}')
if [[ -z "$DEFAULT_SINK" ]]; then
    DEFAULT_SINK=$(wpctl status | awk '/Sinks:/{f=1;next} f && /\*/ {print $2; exit}')
fi

if [[ -z "$DEFAULT_SINK" ]]; then
    error "No default audio sink found."
    aplay -l 2>/dev/null || true
    exit 1
fi

info "Using sink: $DEFAULT_SINK"

wpctl set-mute "$DEFAULT_SINK" 0 2>/dev/null || true
wpctl set-volume "$DEFAULT_SINK" 0.70 2>/dev/null || true

info "Sink state:"
wpctl get-volume "$DEFAULT_SINK" 2>/dev/null || true

if command -v speaker-test &>/dev/null; then
    info "Playing a short test tone (1 second)..."
    timeout 1 speaker-test -t sine -f 1000 -l 1 >/dev/null 2>&1 || \
        warn "speaker-test failed; sink exists but output may still be blocked."
else
    warn "Install alsa-utils for speaker-test if you want an audible check."
fi

if [[ -x "$HOME/.config/polybar/launch.sh" ]]; then
    info "Refreshing polybar volume module..."
    "$HOME/.config/polybar/launch.sh"
fi

echo
info "Audio repair finished."
echo "Try a YouTube/browser video again. Use polybar scroll on the volume bar to adjust level."
