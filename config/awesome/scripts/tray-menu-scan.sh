#!/usr/bin/env bash
# List systray embed windows left-to-right for alignment during tray clicks.
# Output: INDEX PRIMARY_CLASS SECONDARY_CLASS WM_NAME

export DISPLAY="${DISPLAY:-:0}"

is_tray_sized() {
    local wid=$1
    eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || return 1
    [[ "${WIDTH:-999}" -ge 8 && "${HEIGHT:-999}" -ge 8 && "${WIDTH:-0}" -le 64 && "${HEIGHT:-0}" -le 64 ]]
}

read_wm_class() {
    local wid=$1
    local line primary secondary
    line="$(xprop -id "$wid" WM_CLASS 2>/dev/null || true)"
    primary="$(sed -n 's/^WM_CLASS(STRING) = "\([^"]*\)".*/\1/p' <<<"$line")"
    secondary="$(sed -n 's/^WM_CLASS(STRING) = "[^"]*", "\([^"]*\)".*/\1/p' <<<"$line")"
    [[ -z "$primary" ]] && primary="unknown"
    [[ -z "$secondary" ]] && secondary="$primary"
    printf '%s %s' "$primary" "$secondary"
}

read_wm_name() {
    local wid=$1
    local line
    line="$(xprop -id "$wid" WM_NAME 2>/dev/null || true)"
    sed -n 's/^WM_NAME(.*) = "\(.*\)".*/\1/p' <<<"$line" | tr '\n' ' '
}

declare -A seen=()
sorted=()

while IFS= read -r wid; do
    [[ -z "$wid" || -n "${seen[$wid]:-}" ]] && continue
    is_tray_sized "$wid" || continue
    seen[$wid]=1
    eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || continue
    sorted+=("$X:$wid")
done < <(
    {
        xdotool search --onlyvisible --name "." 2>/dev/null || true
        xdotool search --name "." 2>/dev/null || true
    } | sort -u
)

if ((${#sorted[@]} == 0)); then
    exit 0
fi

mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -n -t: -k1)

index=0
for entry in "${sorted[@]}"; do
    wid=${entry#*:}
    read -r primary secondary <<<"$(read_wm_class "$wid")"
    name="$(read_wm_name "$wid")"
    printf '%s %s %s %s\n' "$index" "$primary" "$secondary" "$name"
    index=$((index + 1))
done
