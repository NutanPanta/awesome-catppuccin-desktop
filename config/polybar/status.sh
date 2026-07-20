#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"

expected=$(polybar --list-monitors 2>/dev/null | wc -l)
(( expected == 0 )) && expected=1

for _ in {1..50}; do
    procs=$(pgrep -c -x polybar 2>/dev/null || echo 0)
    windows=$(xdotool search --class polybar 2>/dev/null | wc -l)

    if (( procs == expected && windows == expected )); then
        break
    fi

    # Nothing running and no windows left to wait for.
    if (( procs == 0 && windows == 0 )); then
        break
    fi

    sleep 0.1
done

procs=$(pgrep -c -x polybar 2>/dev/null || echo 0)
windows=$(xdotool search --class polybar 2>/dev/null | wc -l)

echo "polybar processes: ${procs}"
echo "polybar windows:   ${windows}"

if (( windows > 0 )); then
    for wid in $(xdotool search --class polybar 2>/dev/null); do
        pid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        name=$(xprop -id "$wid" WM_NAME 2>/dev/null | cut -d= -f2-)
        geom=$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null | rg '^WIDTH=|^HEIGHT=|^X=|^Y=' | paste -sd' ' -)
        echo "  wid=${wid} pid=${pid} ${geom} name=${name}"
    done
fi

if (( procs == expected && windows == expected )); then
    echo "OK"
    exit 0
fi

echo "Expected ${expected} process(es) and ${expected} window(s) per monitor."
exit 1
