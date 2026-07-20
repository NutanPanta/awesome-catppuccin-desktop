#!/usr/bin/env bash
# Apply Catppuccin LightDM greeter theme (requires root).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${PKEXEC_UID:-}" ]]; then
    TARGET_USER="$(id -un "$PKEXEC_UID")"
elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="$(logname 2>/dev/null || true)"
fi

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == root ]]; then
    echo "Could not determine desktop user. Run: pkexec env SUDO_USER=\$USER $0" >&2
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

GTK_THEME="catppuccin-mocha-mauve-standard+default"
THEME_CSS="/usr/share/themes/${GTK_THEME}/gtk-3.0/gtk.css"
WALLPAPER_SRC="${TARGET_HOME}/.config/wallpapers/Eva Mocha.png"
WALLPAPER_DEST="/usr/share/backgrounds/awesome-catppuccin/eva-mocha.png"
CSS_MARKER_BEGIN="/* BEGIN awesome-catppuccin-desktop lightdm */"
CSS_MARKER_END="/* END awesome-catppuccin-desktop lightdm */"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: pkexec $0" >&2
    exit 1
fi

if [[ ! -d "/usr/share/themes/${GTK_THEME}" ]]; then
    echo "Install the Catppuccin GTK theme first (e.g. yay -S catppuccin-gtk-theme-mauve)." >&2
    exit 1
fi

if [[ ! -f "$WALLPAPER_SRC" ]]; then
    echo "Wallpaper not found: ${WALLPAPER_SRC}" >&2
    echo "Run ./install.sh first, or pick a wallpaper with Super+w." >&2
    exit 1
fi

echo "[lightdm] Installing greeter config..."
install -Dm644 "${REPO_ROOT}/config/lightdm/lightdm-gtk-greeter.conf" /etc/lightdm/lightdm-gtk-greeter.conf

echo "[lightdm] Installing login wallpaper..."
install -Dm644 "$WALLPAPER_SRC" "$WALLPAPER_DEST"

echo "[lightdm] Patching GTK theme for greeter styling..."
python3 - "$THEME_CSS" "$CSS_MARKER_BEGIN" "$CSS_MARKER_END" "${REPO_ROOT}/config/lightdm/greeter.css" <<'PY'
import pathlib
import sys

theme_css = pathlib.Path(sys.argv[1])
marker_begin = sys.argv[2]
marker_end = sys.argv[3]
snippet = pathlib.Path(sys.argv[4]).read_text()

text = theme_css.read_text()
while marker_begin in text:
    start = text.index(marker_begin)
    end = text.index(marker_end, start) + len(marker_end)
    text = text[:start] + text[end:]

text = text.rstrip() + "\n\n" + marker_begin + "\n" + snippet.rstrip() + "\n" + marker_end + "\n"
theme_css.write_text(text)
PY

echo "[lightdm] Ensuring LightDM is enabled..."
systemctl enable lightdm.service >/dev/null

echo
echo "Done. Log out to see the updated login screen."
