#!/usr/bin/env bash
# Right-click a systray embed by class and optional tray index.

set -uo pipefail

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

embed_class="${1:-}"
click_x="${2:-0}"
click_y="${3:-0}"
embed_index="${4:-}"

log() {
    logger -t awesome-tray -- "$*" 2>/dev/null || true
}

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

find_embed_by_index() {
    local target=$1
    declare -a sorted=()
    declare -A seen=()

    while IFS= read -r wid; do
        [[ -z "$wid" || -n "${seen[$wid]:-}" ]] && continue
        is_tray_sized "$wid" || continue
        seen[$wid]=1
        eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || continue
        sorted+=("$X:$wid")
    done < <(
        timeout 2 bash -c '
            xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -oE "0x[0-9a-fA-F]+" || true
            xdotool search --class snixembed 2>/dev/null || true
            xdotool search --class Snixembed 2>/dev/null || true
        ' 2>/dev/null | sort -u
    )

    if ((${#sorted[@]} == 0)); then
        return 1
    fi

    mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -n -t: -k1)
    local index=0
    for entry in "${sorted[@]}"; do
        if [[ "$index" -eq "$target" ]]; then
            echo "${entry#*:}"
            return 0
        fi
        index=$((index + 1))
    done
}

find_embed_at_point() {
    local px=$1
    local py=$2
    local wid best="" best_dist=999999 dist cx cy

    while IFS= read -r wid; do
        [[ -z "$wid" ]] && continue
        is_tray_sized "$wid" || continue
        eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || continue
        cx=$((X + WIDTH / 2))
        cy=$((Y + HEIGHT / 2))
        dist=$(((px - cx) * (px - cx) + (py - cy) * (py - cy)))
        if (( dist < best_dist )); then
            best_dist=$dist
            best=$wid
        fi
    done < <(
        timeout 2 bash -c '
            xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -oE "0x[0-9a-fA-F]+" || true
            xdotool search --class snixembed 2>/dev/null || true
            xdotool search --class Snixembed 2>/dev/null || true
        ' 2>/dev/null | sort -u
    )

    if [[ -n "$best" && "$best_dist" -le $((72 * 72)) ]]; then
        echo "$best"
    fi
}

find_embed() {
    local class=$1
    local wid best="" best_area=0 area w h candidate

    for candidate in "$class" "${class,}" "${class^}"; do
        [[ -z "$candidate" ]] && continue
        while IFS= read -r wid; do
            [[ -z "$wid" ]] && continue
            eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || continue
            w=${WIDTH:-0}
            h=${HEIGHT:-0}
            [[ "$w" -ge 8 && "$h" -ge 8 && "$w" -le 64 && "$h" -le 64 ]] || continue
            area=$((w * h))
            if (( area > best_area )); then
                best_area=$area
                best=$wid
            fi
        done < <(xdotool search --class "$candidate" 2>/dev/null || true)
    done

    echo "$best"
}

log "embed-click start class=$embed_class index=$embed_index x=$click_x y=$click_y"

[[ -n "$embed_class" ]] || { log "embed-click fail: empty class"; exit 1; }
command -v xdotool >/dev/null || { log "embed-click fail: no xdotool"; exit 1; }
pgrep -x snixembed >/dev/null || { log "embed-click fail: snixembed not running"; exit 1; }

wid=""
if [[ "$click_x" =~ ^-?[0-9]+$ && "$click_y" =~ ^-?[0-9]+$ && "$click_x" != "0" || "$click_y" != "0" ]]; then
    wid=$(find_embed_at_point "$click_x" "$click_y")
fi
if [[ -z "$wid" && -n "$embed_index" && "$embed_index" =~ ^[0-9]+$ ]]; then
    wid=$(find_embed_by_index "$embed_index")
fi
if [[ -z "$wid" ]]; then
    wid=$(find_embed "$embed_class")
fi

if [[ -z "$wid" ]]; then
    if [[ "$click_x" =~ ^-?[0-9]+$ && "$click_y" =~ ^-?[0-9]+$ && ( "$click_x" != "0" || "$click_y" != "0" ) ]]; then
        log "embed-click screen-only at $click_x,$click_y class=$embed_class"
        xdotool mousemove --sync "$click_x" "$click_y"
        sleep 0.08
        xdotool click --clearmodifiers 3
        exit 0
    fi
    log "embed-click fail: no embed for class=$embed_class index=$embed_index"
    exit 1
fi

if ! eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"; then
    log "embed-click fail: geometry for wid=$wid"
    exit 1
fi

log "embed-click wid=$wid geom=${WIDTH}x${HEIGHT} at ${X},${Y} class=$embed_class index=$embed_index"

xdotool mousemove --window "$wid" $((WIDTH / 2)) $((HEIGHT / 2))
sleep 0.05
xdotool click --window "$wid" --clearmodifiers 3

if [[ "$click_x" =~ ^-?[0-9]+$ && "$click_y" =~ ^-?[0-9]+$ && ( "$click_x" != "0" || "$click_y" != "0" ) ]]; then
    xdotool mousemove --sync "$click_x" "$click_y"
    sleep 0.05
    xdotool click --clearmodifiers 3
    log "embed-click screen at $click_x,$click_y class=$embed_class"
fi

log "embed-click done class=$embed_class wid=$wid"
exit 0
