#!/usr/bin/env python3

import atexit
import os
import re
import subprocess
import sys
import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk

ENV = os.environ.copy()
ENV.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
ENV.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={ENV['XDG_RUNTIME_DIR']}/bus")

PIDFILE = f"/tmp/volume-slider-{os.getuid()}.pid"

COLORS = {
    "base": "#1e1e2e",
    "surface": "#313244",
    "text": "#cdd6f4",
    "sky": "#89dceb",
    "overlay": "#6c7086",
    "mauve": "#cba6f7",
}

POPUP_W = 340
POPUP_H = 108
POPUP_Y = 62


def run(cmd):
    return subprocess.run(
        cmd,
        env=ENV,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )


def ui_font(root, size=10, bold=False):
    families = set(tkfont.families(root))
    for name in ("DejaVu Sans", "Liberation Sans", "Noto Sans", "Sans"):
        if name in families:
            return (name, size, "bold" if bold else "normal")
    return (tkfont.nametofont("TkDefaultFont").actual("family"), size, "bold" if bold else "normal")


def get_state():
    result = run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
    if result.returncode == 0 and result.stdout.strip():
        raw = result.stdout.strip()
        muted = "[MUTED]" in raw
        match = re.search(r"([0-9]+(?:[.,][0-9]+)?)", raw.split(":", 1)[-1])
        if match:
            value = float(match.group(1).replace(",", "."))
            pct = max(0, min(100, int(round(value * 100))))
            return muted, pct

    result = run(["pactl", "get-sink-mute", "@DEFAULT_SINK@"])
    muted = result.stdout.strip().endswith("yes") if result.returncode == 0 else False

    result = run(["pactl", "get-sink-volume", "@DEFAULT_SINK@"])
    pct = 0
    if result.returncode == 0:
        match = re.search(r"(\d+)%", result.stdout)
        if match:
            pct = int(match.group(1))

    return muted, pct


def set_absolute(pct):
    pct = max(0, min(100, int(pct)))
    level = f"{pct / 100:.2f}"

    if run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"]).returncode == 0:
        run(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", level])
        return

    run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "0"])
    run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{pct}%"])


def set_mute(muted):
    flag = "1" if muted else "0"
    if run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", flag]).returncode == 0:
        return
    run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", flag])


def widget_in_popup(widget, popup_root):
    while widget is not None:
        if widget == popup_root:
            return True
        widget = widget.master
    return False


def focus_in_popup(popup_root):
    try:
        focus = popup_root.focus_get()
    except (KeyError, tk.TclError):
        focus = None

    if focus is None:
        return False
    return widget_in_popup(focus, popup_root)


def pointer_in_popup(popup_root):
    try:
        x, y = popup_root.winfo_pointerxy()
        target = popup_root.winfo_containing(x, y)
    except tk.TclError:
        return False

    if not target:
        return False
    return widget_in_popup(target, popup_root)


def cleanup_pidfile():
    try:
        os.remove(PIDFILE)
    except FileNotFoundError:
        pass


def main():
    muted, pct = get_state()
    if muted:
        pct = 0

    with open(PIDFILE, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))
    atexit.register(cleanup_pidfile)

    root = tk.Tk()
    root.title("Volume")
    root.configure(bg=COLORS["surface"])
    root.overrideredirect(True)
    root.attributes("-topmost", True)

    popup_x = root.winfo_screenwidth() - POPUP_W - 24
    root.geometry(f"{POPUP_W}x{POPUP_H}+{popup_x}+{POPUP_Y}")

    title_font = ui_font(root, 11, bold=True)
    button_font = ui_font(root, 10)

    closing = {"value": False}
    drag_state = {"active": False}

    def close_popup(_event=None):
        if closing["value"]:
            return
        closing["value"] = True
        cleanup_pidfile()
        try:
            root.quit()
        except tk.TclError:
            pass
        try:
            root.destroy()
        except tk.TclError:
            pass

    def maybe_close_on_outside():
        if closing["value"]:
            return
        if drag_state["active"]:
            root.after(100, maybe_close_on_outside)
            return
        if focus_in_popup(root) or pointer_in_popup(root):
            root.after(100, maybe_close_on_outside)
            return
        close_popup()

    root.bind("<Escape>", close_popup)
    root.protocol("WM_DELETE_WINDOW", close_popup)
    root.bind("<FocusOut>", lambda _event: root.after(80, maybe_close_on_outside))

    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure(
        "Sky.Horizontal.TScale",
        background=COLORS["surface"],
        troughcolor=COLORS["base"],
        bordercolor=COLORS["surface"],
        lightcolor=COLORS["sky"],
        darkcolor=COLORS["sky"],
    )
    style.configure(
        "Bar.TButton",
        font=button_font,
        background=COLORS["base"],
        foreground=COLORS["text"],
        bordercolor=COLORS["overlay"],
        focusthickness=0,
        padding=(12, 6),
    )
    style.map(
        "Bar.TButton",
        background=[("active", COLORS["overlay"]), ("pressed", COLORS["overlay"])],
        foreground=[("active", COLORS["text"])],
    )

    frame = tk.Frame(
        root,
        bg=COLORS["surface"],
        highlightbackground=COLORS["mauve"],
        highlightthickness=1,
        padx=14,
        pady=12,
    )
    frame.pack(fill="both", expand=True)

    header = tk.Frame(frame, bg=COLORS["surface"])
    header.pack(fill="x", pady=(0, 10))

    tk.Label(
        header,
        text="Speaker volume",
        bg=COLORS["surface"],
        fg=COLORS["text"],
        font=title_font,
    ).pack(side="left")

    level_var = tk.StringVar(value=f"{pct}%")
    tk.Label(
        header,
        textvariable=level_var,
        bg=COLORS["surface"],
        fg=COLORS["sky"],
        font=title_font,
    ).pack(side="right")

    slider = ttk.Scale(
        frame,
        from_=0,
        to=100,
        orient="horizontal",
        style="Sky.Horizontal.TScale",
        length=300,
    )
    slider.set(pct)
    slider.pack(fill="x")

    footer = tk.Frame(frame, bg=COLORS["surface"])
    footer.pack(fill="x", pady=(12, 0))

    mute_text = tk.StringVar(value="Unmute" if muted else "Mute")
    updating = {"active": False}

    def apply_volume(value):
        value = int(float(value))
        level_var.set(f"{value}%")
        updating["active"] = True
        set_absolute(value)
        if value > 0:
            mute_text.set("Mute")
        updating["active"] = False

    slider.configure(command=apply_volume)
    slider.bind("<ButtonPress-1>", lambda _e: drag_state.__setitem__("active", True))
    slider.bind("<ButtonRelease-1>", lambda _e: drag_state.__setitem__("active", False))

    def toggle_mute():
        if updating["active"]:
            return
        new_muted = mute_text.get() == "Mute"
        set_mute(new_muted)
        if new_muted:
            slider.set(0)
            level_var.set("0%")
            mute_text.set("Unmute")
        else:
            restore = max(pct, 30)
            slider.set(restore)
            level_var.set(f"{restore}%")
            set_absolute(restore)
            mute_text.set("Mute")

    ttk.Button(
        footer,
        textvariable=mute_text,
        command=toggle_mute,
        style="Bar.TButton",
        width=10,
    ).pack(side="left")

    root.update_idletasks()
    root.focus_force()
    root.after(150, maybe_close_on_outside)

    try:
        root.mainloop()
    finally:
        cleanup_pidfile()

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except tk.TclError as exc:
        cleanup_pidfile()
        print(f"Volume slider failed: {exc}", file=sys.stderr)
        sys.exit(1)
