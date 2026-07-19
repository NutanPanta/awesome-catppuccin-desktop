# Awesome WM + Catppuccin Desktop

One-shot installer for the **Awesome WM + Catppuccin Mocha** desktop on Arch Linux (ThinkPad X9 setup). This repo contains **desktop design only** — no camera / IPU7 stack.

Inspired by [Catppuccin on Arch (Reddit)](https://www.reddit.com/r/linux4noobs/comments/1f4k0wj/catppuccin_arch_linux_theme/) and customized for:

- Catppuccin Mocha palette across Awesome, Polybar, Rofi, Kitty, Dunst, GTK
- Center **taskbar pill** (HyDE-style dock) in Awesome
- **Polybar** top bar: menu, workspaces, system info, volume slider, WiFi, Bluetooth, power
- **Picom** blur and rounded corners
- **PipeWire** audio profile (libcamera monitor disabled so audio stays working)
- **feh** wallpapers

## Quick start

```bash
git clone https://github.com/YOUR_USER/awesome-catppuccin-desktop.git
cd awesome-catppuccin-desktop
chmod +x install.sh
./install.sh
```

Optional GTK theme (recommended):

```bash
yay -S catppuccin-gtk-theme-mocha
```

Log out and back in, then choose **Awesome** at the login screen.

## What `install.sh` does

1. Installs packages from `packages.txt` via `pacman`
2. Backs up any existing configs to `~/.config-backups/<timestamp>/`
3. Copies configs into `~/.config/` (awesome, polybar, rofi, picom, kitty, dunst, gtk, wallpapers, wireplumber)
4. Installs `~/.fehbg` for the default wallpaper
5. Disables the global PipeWire libcamera module if present (fixes silent audio on this machine)
6. Restarts PipeWire user services

### Options

| Flag | Effect |
|------|--------|
| `./install.sh` | Full install (packages + configs) |
| `./install.sh --config-only` | Skip pacman, only deploy configs |
| `./install.sh --dry-run` | Print actions without changing anything |
| `./install.sh --help` | Show help |

## Repo layout

```
.
├── install.sh           # Main installer — run this
├── packages.txt         # Arch pacman packages
├── fehbg                # Wallpaper script → ~/.fehbg
└── config/
    ├── awesome/         # rc.lua, autostart, theme, taskbar pill, volume OSD
    ├── polybar/         # Top bar + scripts
    ├── rofi/            # Launcher + powermenu + wallpaper picker
    ├── picom/           # Compositor
    ├── kitty/           # Terminal colors
    ├── dunst/           # Notifications
    ├── gtk-3.0/         # GTK theme hints
    ├── gtk-4.0/
    ├── wireplumber/     # Audio-only WirePlumber profile
    └── wallpapers/      # Default Catppuccin wallpapers
```

## After install

| Task | Command |
|------|---------|
| Fix audio | `bash ~/.config/awesome/fix-audio.sh` |
| Reload Awesome | `Super+Ctrl+r` |
| Reload polybar | `polybar-msg cmd restart` |
| Change wallpaper | `Super+w` (rofi picker) |
| Powermenu | `Super+Shift+e` |

## Keybindings (default)

| Keys | Action |
|------|--------|
| `Super+Enter` | Kitty terminal |
| `Super+d` / `Super+r` | Rofi app launcher |
| `Super+Shift+e` | Powermenu |
| `Super+w` | Wallpaper picker |
| `Print` | Flameshot |
| `Super+1–9` | Switch workspace / tag |
| `Super+Shift+q` | Kill focused window |

## Not included

This repo intentionally **does not** include:

- IPU7 / IMX471 camera bridge (`fix-camera.sh`, `ipu7-camera-dynamic`, etc.)
- Intel HAL, v4l2loopback, or camera tuning scripts

Keep camera setup separate if you need it on ThinkPad X9.

## Requirements

- Arch Linux (or Arch-based with `pacman`)
- Awesome WM session (display manager or `~/.xinitrc`)
- Optional: `yay` for Catppuccin GTK theme from AUR

## License

Config files are personal dotfiles — use and modify freely. Third-party scripts in `rofi/scripts/` may carry their own licenses (see file headers).
