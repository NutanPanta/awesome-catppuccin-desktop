#!/usr/bin/env bash
# Touchscreen gestures via touchegg (requires input group + re-login once).
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

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: pkexec $0" >&2
    exit 1
fi

if ! command -v touchegg >/dev/null; then
    echo "Install touchegg first: sudo pacman -S touchegg xorg-xinput" >&2
    exit 1
fi

echo "[touch] Adding ${TARGET_USER} to input group (log out/in once)..."
if id -nG "$TARGET_USER" | tr ' ' '\n' | rg -qx input; then
    echo "Already in input group."
else
    usermod -aG input "$TARGET_USER"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
install -Dm644 "${REPO_ROOT}/config/touchegg/touchegg.conf" "${TARGET_HOME}/.config/touchegg/touchegg.conf"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/touchegg"

# Session autostart is handled by awesome; system unit needs DISPLAY for xdotool.
systemctl disable touchegg.service 2>/dev/null || true

echo
echo "Done. Log out and back in, then reload Awesome (Super+Shift+r)."
echo "Touchegg starts automatically from ~/.config/awesome/autostart.sh."
