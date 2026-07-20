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
FINGERPRINT_SENSOR=0
LOCK_SCREEN_BIN="${HOME}/.local/bin/lock-screen"

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

If a previous install left root-owned files (e.g. from pkexec setup scripts),
install.sh backs them up, removes them with one sudo prompt, and redeploys
with your user ownership automatically.

After install:
  1. Log out and back in (or reboot) if you were added to new groups
  2. Select Awesome from your display manager, or: echo exec awesome > ~/.xinitrc
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

require_deploy_tools() {
    local -a missing=()
    local cmd

    for cmd in rsync cp mkdir find; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    err "Missing tools required to deploy configs: ${missing[*]}"
    if [[ "$INSTALL_PACKAGES" -eq 0 ]]; then
        err "Re-run without --config-only, or install manually: sudo pacman -S rsync"
    else
        err "Package install did not provide required tools. Try: sudo pacman -S rsync"
    fi
    exit 1
}

has_fingerprint_sensor() {
    local out

    if command -v fprintd-list >/dev/null 2>&1; then
        out=$(fprintd-list "$USER" 2>/dev/null) || true
        if [[ "$out" =~ found\ ([1-9][0-9]*)\ devices ]] || [[ "$out" == *"Device at "* ]]; then
            return 0
        fi
    fi

    if command -v lsusb >/dev/null 2>&1; then
        if lsusb 2>/dev/null | grep -qiE \
            'finger|fprint|goodix.*moc|synaptics.*metallica|elan.*fingerprint|058f:9540|06cb:00bd|27c6:5[0-9a-f]{3}'; then
            return 0
        fi
    fi

    [[ -d /sys/class/fingerprint ]]
}

detect_fingerprint_sensor() {
    if has_fingerprint_sensor; then
        FINGERPRINT_SENSOR=1
        log "Fingerprint sensor detected."
    else
        FINGERPRINT_SENSOR=0
        log "No fingerprint sensor detected — using password-only lock screen."
    fi
}

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

    if [[ "$FINGERPRINT_SENSOR" -eq 1 ]]; then
        pkgs+=(fprintd)
        log "Including fprintd for fingerprint unlock."
    fi

    log "Installing ${#pkgs[@]} pacman packages..."
    run sudo pacman -S --needed --noconfirm "${pkgs[@]}"
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

prepare_deploy_dest() {
    local path="$1"
    local kind="${2:-dir}"

    run mkdir -p "$(dirname "$path")"

    if [[ ! -e "$path" ]]; then
        if [[ "$kind" == dir ]]; then
            run mkdir -p "$path"
        fi
        return 0
    fi

    if [[ -O "$path" && -w "$path" ]]; then
        return 0
    fi

    warn "Replacing protected ${path} (sudo required once)..."
    if ! run sudo rm -rf "$path"; then
        err "Install needs sudo to replace ${path}."
        err "Approve the prompt when asked, then re-run ./install.sh"
        return 1
    fi

    if [[ "$kind" == dir ]]; then
        run mkdir -p "$path"
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

    if [[ -d "$src" ]]; then
        prepare_deploy_dest "$dest" dir || return 1
        if ! run rsync -a --delete --no-owner --no-group "${src}/" "${dest}/"; then
            err "Failed to deploy .config/${name}"
            return 1
        fi
    else
        prepare_deploy_dest "$dest" file || return 1
        if ! run cp -a "$src" "$dest"; then
            err "Failed to deploy .config/${name}"
            return 1
        fi
        run chmod u+rw "$dest" 2>/dev/null || true
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
    prepare_deploy_dest "$dest" file || return 1
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

install_lock_screen() {
    local bindir="${HOME}/.local/bin"
    local icondir="${HOME}/.local/share/i3lock-fancy/icons"
    local src_icons="${REPO_ROOT}/assets/i3lock-fancy/icons"
    local script target
    local -a scripts=(i3lock-fancy)

    run mkdir -p "$bindir" "$icondir"

    if [[ "$FINGERPRINT_SENSOR" -eq 1 ]]; then
        scripts+=(i3lock-fancy-fingerprint)
        target="${bindir}/i3lock-fancy-fingerprint"
    else
        run rm -f "${bindir}/i3lock-fancy-fingerprint"
        target="${bindir}/i3lock-fancy"
    fi

    for name in "${scripts[@]}"; do
        script="${REPO_ROOT}/scripts/${name}"
        if [[ ! -f "$script" ]]; then
            warn "Missing lock script: ${script}"
            continue
        fi
        run cp -a "$script" "${bindir}/${name}"
        run chmod +x "${bindir}/${name}"
        log "Installed ~/.local/bin/${name}"
    done

    if [[ -d "$src_icons" ]]; then
        run cp -a "${src_icons}/." "$icondir/"
        log "Installed lock screen icons -> ~/.local/share/i3lock-fancy/icons"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${BLUE}[dry-run]${NC} write ${LOCK_SCREEN_BIN} -> exec ${target}"
        return 0
    fi

    cat > "$LOCK_SCREEN_BIN" <<EOF
#!/usr/bin/env bash
# Installed by awesome-catppuccin-desktop install.sh — do not edit.
exec "${target}" "\$@"
EOF
    chmod +x "$LOCK_SCREEN_BIN"
    log "Installed ${LOCK_SCREEN_BIN#${HOME}/} -> ${target#${HOME}/}"

    if [[ "$FINGERPRINT_SENSOR" -eq 1 ]] && ! command -v fprintd-verify >/dev/null 2>&1; then
        warn "fprintd is missing — install packages or run: sudo pacman -S fprintd"
    fi
}

run_optional_setup() {
    local script="$1"
    local label="$2"

    if [[ ! -x "$script" ]]; then
        return 0
    fi

    warn "${label} (requires root — run manually if needed):"
    echo "  pkexec env SUDO_USER=${USER} ${script}"
}

print_summary() {
    local lock_note="Password lock screen (~/.local/bin/i3lock-fancy)"
    if [[ "$FINGERPRINT_SENSOR" -eq 1 ]]; then
        lock_note="Fingerprint lock screen (~/.local/bin/i3lock-fancy-fingerprint)"
    fi

    cat <<EOF

${GREEN}Done.${NC} Desktop configs are installed.

${BLUE}Included:${NC}
  • Awesome WM (Catppuccin Mocha, center taskbar pill, volume OSD)
  • Polybar (menu, workspaces, volume slider, WiFi, Bluetooth, power)
  • Picom blur, Rofi launcher, Kitty terminal, Dunst notifications
  • GTK 3/4 theme hints, PipeWire audio profile, wallpapers via feh
  • ${lock_note}

${BLUE}Next steps:${NC}
  1. Log out and log back in (or reboot)
  2. Choose Awesome at the login screen
  3. If audio is silent: bash ~/.config/awesome/fix-audio.sh
  4. Touchscreen gestures: pkexec env SUDO_USER=${USER} ${REPO_ROOT}/scripts/setup-touch.sh
  5. LightDM greeter theme: pkexec env SUDO_USER=${USER} ${REPO_ROOT}/scripts/setup-lightdm.sh
  6. Before reloading Awesome: ~/.config/awesome/scripts/check-config.sh

${BLUE}Keybindings (defaults):${NC}
  Super+Enter     kitty
  Super+p         rofi app launcher
  Super+d         calculator
  Super+w         wallpaper picker
  Print           flameshot

Backup of replaced files: ${BACKUP_ROOT}/${TIMESTAMP}

EOF
}

main() {
    log "Awesome + Catppuccin desktop installer"
    log "Repo: ${REPO_ROOT}"

    detect_fingerprint_sensor

    if [[ "$INSTALL_PACKAGES" -eq 1 ]]; then
        install_packages
    else
        log "Skipping package install (--config-only)."
    fi

    require_deploy_tools

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
    deploy_tree "xfce4"
    deploy_tree "touchegg"
    deploy_fehbg

    install_lock_screen
    fix_pipewire_audio
    make_scripts_executable

    run_optional_setup "${REPO_ROOT}/scripts/setup-touch.sh" "Touchscreen (input group + touchegg)"
    run_optional_setup "${REPO_ROOT}/scripts/setup-lightdm.sh" "LightDM greeter"

    print_summary
}

main "$@"
