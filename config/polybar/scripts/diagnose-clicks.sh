#!/usr/bin/env bash
# Diagnose polybar bar clicks: ghost windows, overlays, and trace logging.
set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
BAR_H="${POLYBAR_BAR_H:-60}"
LOG="${1:-/tmp/polybar-click-diagnose.log}"
TRACE_SECS="${TRACE_SECS:-0}"

section() { printf '\n=== %s ===\n' "$1"; }

section "Polybar process / window count"
if [[ -x "${HOME}/.config/polybar/status.sh" ]]; then
    "${HOME}/.config/polybar/status.sh" || true
else
    echo "polybar processes: $(pgrep -c -x polybar 2>/dev/null || echo 0)"
    echo "polybar windows:   $(xdotool search --class polybar 2>/dev/null | wc -l)"
fi

section "Windows overlapping the top bar (y < ${BAR_H})"
found=0
while read -r wid; do
    [[ -z "$wid" ]] && continue
    eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null || continue)"
    if (( Y < BAR_H && Y + HEIGHT > 0 && WIDTH > 0 )); then
        name=$(xprop -id "$wid" WM_NAME 2>/dev/null | cut -d= -f2- | xargs)
        cls=$(xprop -id "$wid" WM_CLASS 2>/dev/null | tr '\n' ' ' | xargs)
        pid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        printf '  wid=%s %dx%d+%d+%d pid=%s\n    class: %s\n    name:  %s\n' \
            "$wid" "$WIDTH" "$HEIGHT" "$X" "$Y" "${pid:-?}" "$cls" "$name"
        found=1
    fi
done < <(xdotool search --onlyvisible --name . 2>/dev/null || true)
(( found == 0 )) && echo "  (none besides expected bar widgets)"

section "Picker / menu processes (should be empty when idle)"
pgrep -af 'wifi-picker|bluetooth-picker|volume-picker|powermenu|volume-slider' 2>/dev/null \
    | grep -v 'diagnose-clicks' || echo "  (none)"

section "Click wrapper present"
wrapper="${HOME}/.config/polybar/scripts/run-module-click.sh"
if [[ -x "$wrapper" ]]; then
    echo "  OK: $wrapper"
else
    echo "  MISSING: $wrapper"
    echo "  Without this, polybar blocks on rofi until the menu closes and may miss clicks."
fi

section "How to read polybar click logs"
cat <<'EOF'
Polybar does not keep a log file by default. To capture clicks live:

  ~/.config/polybar/restart.sh
  polybar-msg cmd quit
  polybar -l trace bar1 2>&1 | tee /tmp/polybar-click-diagnose.log

Then click an icon twice (open menu, close it, click again). Stop with Ctrl+C.

What the log means for the SECOND click:

  (nothing about "Received button press")
    -> Click never reached polybar. Something on top is eating it (rofi ghost,
       Awesome mousegrabber after volume popup, duplicate polybar window).

  "Received button press" + "No matching input area"
    -> Polybar saw the click but lost module hit-boxes (often pseudo-transparency
       or a stale bar window after redraw).

  "Received button press" + "Found matching input area" + "Executing shell command"
    -> Click registered; if nothing opens, the script failed (check script output).

  First click shows "Executing shell command" but no "Exited with status" for a
  long time while rofi is open
    -> Click handler still blocking polybar (run-module-click.sh missing or broken).
EOF

if (( TRACE_SECS > 0 )); then
    section "Capturing ${TRACE_SECS}s of trace to ${LOG}"
    polybar-msg cmd quit 2>/dev/null || true
    sleep 1
    : >"$LOG"
    polybar -l trace bar1 >>"$LOG" 2>&1 &
    pb_pid=$!
    sleep 2
    echo "  Trace running (pid ${pb_pid}). Click the bar now..."
    sleep "$TRACE_SECS"
    kill "$pb_pid" 2>/dev/null || true
    wait "$pb_pid" 2>/dev/null || true
    "${HOME}/.config/polybar/restart.sh" >/dev/null 2>&1 || true

    section "Trace summary (${LOG})"
    presses=$(grep -c "Received button press" "$LOG" 2>/dev/null || echo 0)
    matched=$(grep -c "Found matching input area" "$LOG" 2>/dev/null || echo 0)
    missed=$(grep -c "No matching input area" "$LOG" 2>/dev/null || echo 0)
    echo "  button presses:     ${presses}"
    echo "  matched input area: ${matched}"
    echo "  NO input area:      ${missed}"
    echo
    grep -E "Received button press|Found matching|No matching|Executing shell command|Forwarding action" "$LOG" 2>/dev/null | tail -40 || true
fi
