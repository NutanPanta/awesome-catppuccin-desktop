#!/usr/bin/env bash
# Awesome WM + Catppuccin Mocha desktop: one-shot installer for Arch Linux
#
# Usage:
#   ./install.sh              # install packages + deploy configs
#   ./install.sh --config-only
#   ./install.sh --dry-run
#   ./install.sh --help
#
# Desktop theme and session only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${REPO_ROOT}/config"
BACKUP_ROOT="${HOME}/.config-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

INSTALL_PACKAGES=1
DRY_RUN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then echo -e "${BLUE}[dry-run]${NC} $*"; else "$@"; fi; }

usage() {
    cat <<'EOF'
Awesome WM + Catppuccin desktop installer

  ./install.sh                 Install pacman packages and copy configs
  ./install.sh --config-only   Skip package install, only deploy configs
  ./install.sh --dry-run       Show what would happen
  ./install.sh --help          This help

After install:
  1. Log out and back in (or reboot) if you were added to new groups
  2. Select Awesome from your display manager, or: echo exec awesome > ~/.xinitrc
  3. Optional GTK theme: yay -S catppuccin-gtk-theme-mocha
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-only) INSTALL_PACKAGES=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

if [[ "${EUID}" -eq 0 ]]; then
    err "Run as your normal user (not root). The script uses sudo only for pacman."
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    err "This installer targets Arch Linux (pacman not found)."
    exit 1
fi

if [[ ! -d "$CONFIG_SRC" ]]; then
    err "Missing ${CONFIG_SRC} — run this from the cloned repo root."
    exit 1
fi

install_packages() {
    local pkgfile="${REPO_ROOT}/packages.txt"
    local -a pkgs=()
    local line

    if [[ ! -f "$pkgfile" ]]; then
        warn "No packages.txt found — skipping package install."
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "$line" ]] && continue
        pkgs+=("$line")
    done < "$pkgfile"

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi

    log "Installing ${#pkgs[@]} pacman packages..."
    run sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

install_gtk_theme_hint() {
    if pacman -Q catppuccin-gtk-theme-mocha &>/dev/null; then
        log "Catppuccin GTK theme already installed."
        return 0
    fi
    warn "Catppuccin GTK theme not installed."
    warn "For matching app chrome, run: yay -S catppuccin-gtk-theme-mocha"
}

backup_path() {
    local rel="$1"
    echo "${BACKUP_ROOT}/${TIMESTAMP}/${rel}"
}

backup_if_exists() {
    local rel="$1"
    local target="${HOME}/${rel}"
    local dest
    dest="$(backup_path "$rel")"

    if [[ -e "$target" || -L "$target" ]]; then
        run mkdir -p "$(dirname "$dest")"
        run cp -a "$target" "$dest"
        log "Backed up ${rel} -> ${dest}"
    fi
}

deploy_tree() {
    local name="$1"
    local src="${CONFIG_SRC}/${name}"
    local dest="${HOME}/.config/${name}"

    if [[ ! -e "$src" ]]; then
        warn "Skip missing source: ${src}"
        return 0
    fi

    backup_if_exists ".config/${name}"
    run mkdir -p "$(dirname "$dest")"
    if [[ -d "$src" ]]; then
        run mkdir -p "$dest"
        run rsync -a --delete "${src}/" "${dest}/"
    else
        run cp -a "$src" "$dest"
    fi
    log "Deployed .config/${name}"
}

deploy_fehbg() {
    local src="${REPO_ROOT}/fehbg"
    local dest="${HOME}/.fehbg"
    if [[ ! -f "$src" ]]; then
        warn "Missing fehbg in repo root."
        return 0
    fi
    backup_if_exists ".fehbg"
    run cp -a "$src" "$dest"
    run chmod +x "$dest"
    log "Installed ~/.fehbg"
}

fix_pipewire_audio() {
    local dropin="/etc/pipewire/pipewire.conf.d/50-libcamera.conf"
    local disabled="/etc/pipewire/pipewire.conf.d/50-libcamera.conf.disabled"

    if [[ -f "$dropin" ]]; then
        warn "Disabling global libcamera PipeWire module (often breaks audio)..."
        run sudo mv "$dropin" "$disabled"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
        run systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
        if [[ "$DRY_RUN" -eq 0 ]]; then
            systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
        fi
    fi
}

make_scripts_executable() {
    local script
    while IFS= read -r script; do
        run chmod +x "$script"
    done < <(find "${HOME}/.config/awesome" "${HOME}/.config/polybar" "${HOME}/.config/rofi" \
        -type f \( -name '*.sh' -o -name 'launch.sh' -o -name 'fehbg' \) 2>/dev/null)
}

print_summary() {
    cat <<EOF

${GREEN}Done.${NC} Desktop configs are installed.

${BLUE}Included:${NC}
  • Awesome WM (Catppuccin Mocha, center taskbar pill, volume OSD)
  • Polybar (menu, workspaces, volume slider, WiFi, Bluetooth, power)
  • Picom blur, Rofi launcher, Kitty terminal, Dunst notifications
  • GTK 3/4 theme hints, PipeWire audio profile, wallpapers via feh

${BLUE}Next steps:${NC}
  1. Optional: yay -S catppuccin-gtk-theme-mocha
  2. Log out and log back in (or reboot)
  3. Choose Awesome at the login screen
  4. If audio is silent: bash ~/.config/awesome/fix-audio.sh

${BLUE}Keybindings (defaults):${NC}
  Super+Enter     kitty
  Super+d / Super+r   rofi app launcher
  Super+Shift+e   rofi powermenu
  Super+w         wallpaper picker
  Print           flameshot

Backup of replaced files: ${BACKUP_ROOT}/${TIMESTAMP}

EOF
}

main() {
    log "Awesome + Catppuccin desktop installer"
    log "Repo: ${REPO_ROOT}"

    if [[ "$INSTALL_PACKAGES" -eq 1 ]]; then
        install_packages
    else
        log "Skipping package install (--config-only)."
    fi

    install_gtk_theme_hint

    log "Deploying configs (existing files backed up first)..."
    deploy_tree "awesome"
    deploy_tree "polybar"
    deploy_tree "rofi"
    deploy_tree "picom"
    deploy_tree "kitty"
    deploy_tree "dunst"
    deploy_tree "gtk-3.0"
    deploy_tree "gtk-4.0"
    deploy_tree "wallpapers"
    deploy_tree "wireplumber"
    deploy_fehbg

    fix_pipewire_audio
    make_scripts_executable

    print_summary
}

main "$@"
