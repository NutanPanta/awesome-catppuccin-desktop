#!/usr/bin/env bash

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

VOLUME_SEGMENTS=10
VOLUME_FILL="#89dceb"
VOLUME_EMPTY="#45475a"
VOLUME_MUTED="#6c7086"

volume_get_state() {
    if command -v wpctl &>/dev/null; then
        local raw vol pct muted=0
        raw=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || return 1
        [[ "$raw" == *"[MUTED]"* ]] && muted=1
        vol=${raw#Volume: }
        vol=${vol%% *}
        vol=${vol//,/.}
        pct=$(awk "BEGIN {printf \"%.0f\", $vol * 100}")
        echo "$muted $pct"
        return 0
    fi

    local muted vol
    muted=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i ~ /%/) {
                gsub(/%/, "", $i)
                print $i
                exit
            }
        }
    }')
    [[ -z "$vol" ]] && return 1
    echo "$muted ${vol%%.*}"
}

volume_set_step() {
    local dir=$1
    local step=${2:-5}

    if command -v wpctl &>/dev/null; then
        wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "${step}%${dir}" 2>/dev/null && return 0
    fi

    if [[ "$dir" == "+" ]]; then
        pactl set-sink-volume @DEFAULT_SINK@ "+${step}%" 2>/dev/null
    else
        pactl set-sink-volume @DEFAULT_SINK@ "-${step}%" 2>/dev/null
    fi
}

volume_set_absolute() {
    local pct=$1
    local level

    pct=${pct//[^0-9]/}
    [[ -z "$pct" ]] && return 1
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    level=$(awk "BEGIN {printf \"%.2f\", $pct / 100}")

    if command -v wpctl &>/dev/null; then
        wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true
        wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "$level" 2>/dev/null && return 0
    fi

    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
    pactl set-sink-volume @DEFAULT_SINK@ "${pct}%" 2>/dev/null
}

volume_set_mute() {
    local mute=$1

    if command -v wpctl &>/dev/null; then
        wpctl set-mute @DEFAULT_AUDIO_SINK@ "$mute" 2>/dev/null && return 0
    fi

    if [[ "$mute" == "1" ]]; then
        pactl set-sink-mute @DEFAULT_SINK@ 1 2>/dev/null
    else
        pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null
    fi
}

volume_toggle_mute() {
    if command -v wpctl &>/dev/null; then
        wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle 2>/dev/null && return 0
    fi
    pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null
}

volume_bar_markup() {
    local pct=$1
    local muted=$2
    local fill=$VOLUME_FILL
    local empty=$VOLUME_EMPTY

    if [[ "$muted" == "yes" || "$muted" == "1" ]]; then
        fill=$VOLUME_MUTED
        empty=$VOLUME_MUTED
        pct=0
    fi

    local filled=$(( pct * VOLUME_SEGMENTS / 100 ))
    (( filled > VOLUME_SEGMENTS )) && filled=$VOLUME_SEGMENTS

    local out=""
    local i
    for ((i = 0; i < VOLUME_SEGMENTS; i++)); do
        if (( i < filled )); then
            out+="%{F${fill}}█"
        else
            out+="%{F${empty}}░"
        fi
    done
    printf '%s' "$out"
}

volume_icon() {
    local pct=$1
    local muted=$2

    if [[ "$muted" == "yes" || "$muted" == "1" ]]; then
        echo "󰝟"
        return
    fi

    if [[ "$pct" -ge 66 ]]; then
        echo "󰕾"
    elif [[ "$pct" -ge 33 ]]; then
        echo "󰖀"
    else
        echo "󰕿"
    fi
}

volume_notify() {
    local muted=$1
    local pct=$2
    local icon
    icon=$(volume_icon "$pct" "$muted")

    command -v dunstify &>/dev/null || return 0

    if [[ "$muted" == "yes" || "$muted" == "1" ]]; then
        dunstify -a Volume -r 8374 -t 1200 "Volume" "Muted" -i audio-volume-muted
        return
    fi

    local bar_plain=""
    local filled=$(( pct * VOLUME_SEGMENTS / 100 ))
    local i
    for ((i = 0; i < VOLUME_SEGMENTS; i++)); do
        if (( i < filled )); then
            bar_plain+="█"
        else
            bar_plain+="░"
        fi
    done

    dunstify -a Volume -r 8374 -t 1200 "Volume" "${icon}  ${bar_plain}  ${pct}%"
}

volume_polybar_refresh() {
    :
}
