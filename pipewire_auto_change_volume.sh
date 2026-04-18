#!/bin/bash
TARGET_VOL=1.42
VOL_PCT=$(awk -v v="$TARGET_VOL" 'BEGIN{printf "%.0f%%", v*100}')

VOL_EPS=0.005

COOLDOWN_MS=400 # ajustar

declare -A LAST_MS_CACHE=()

DEBOUNCE_MS=130 # não deixar muito baixo!

SLEEP_DEBOUNCE=$(awk -v d=$DEBOUNCE_MS 'BEGIN{printf "%.3f", d/1000}')

pending_file_path() {
    local id=$1
    printf '/tmp/vol-helper-pending-%s' "$id"
}

last_file_path() {
    local id=$1
    printf '/tmp/vol-helper-last-%s' "$id"
}
set_last_ms() {
    local id=$1
    local ts
    ts=$(date +%s%3N)
    date +%s%3N > "$(last_file_path "$id")" 2>/dev/null || true
    LAST_MS_CACHE[$id]=$ts
}
get_last_ms() {
    local id=$1
    if [[ -n ${LAST_MS_CACHE[$id]-} ]]; then
        printf '%s' "${LAST_MS_CACHE[$id]}"
        return
    fi
    local f; f=$(last_file_path "$id")
    if [[ -f $f ]]; then
        local v; v=$(cat "$f" 2>/dev/null || echo 0)
        LAST_MS_CACHE[$id]=$v
        printf '%s' "$v"
    else
        echo 0
    fi
}

needs_set_volume() {
    local id=$1
    local cur cur_num now_ms last
    now_ms=$(date +%s%3N)
    last=$(get_last_ms "$id" || echo 0)
    if [[ -n $last && $last -gt 0 && $((now_ms - last)) -lt $COOLDOWN_MS ]]; then
        return 1
    fi

    cur=$(get_volume "$id" 2>/dev/null || echo "")
    if [[ -z $cur ]]; then
        return 1
    fi
    cur_num=$(printf '%s' "$cur" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)
    if [[ -z $cur_num ]]; then
        return 1
    fi

    awk -v a="$cur_num" -v b="$TARGET_VOL" -v eps="$VOL_EPS" 'BEGIN {d = a - b; if (d < 0) d = -d; if (d > eps) exit 0; exit 1}'
}

get_volume() {
        [[ -z $1 ]] && return 1
        out=$(pactl get-sink-input-volume "$1" 2>/dev/null || true)
        printf '%s' "$out" | awk '
        {
            if (match($0, /[0-9]+(\.[0-9]+)?%/, m)) {
                s = m[0]; sub(/%$/, "", s); printf "%.2f", s/100; exit
            }
            if (match($0, /[0-9]+\.[0-9]+/, m)) { print m[0]; exit }
            if (match($0, /[0-9]+/, m)) {
                s = m[0]; if (s+0 >= 10) { printf "%.2f", s/100 } else { printf "%.2f", s }; exit
            }
        }' || true
}


set_all_streams() {
    local now_ms
    now_ms=$(date +%s%3N)
    if [[ -n ${LAST_ALL_RUN_MS-} && $((now_ms - LAST_ALL_RUN_MS)) -lt 500 ]]; then
        return
    fi
    LAST_ALL_RUN_MS=$now_ms

    pactl list sink-inputs short | awk '{print $1}' | while IFS= read -r id; do
        if [[ -n $id && $id =~ ^[0-9]+$ ]]; then
            if needs_set_volume "$id"; then
                pactl set-sink-input-volume "$id" "$VOL_PCT" >/dev/null 2>&1 || true
                set_last_ms "$id"
            fi
        fi
    done
}

trap 'exit 0' INT TERM

pactl subscribe | while IFS= read -r ev; do
    if [[ $ev != *"sink-input"* ]]; then
        continue
    fi
    read -r _ ev_type _ _ rest <<< "$ev"
    ev_type=${ev_type//[\'\"]/}
    ev_id=$(sed -n 's/.*sink-input #\([0-9]\+\).*/\1/p' <<< "$ev")
    if [[ -z $ev_type || -z $ev_id ]]; then
        continue
    fi

    if [[ $ev_type == "remove" ]]; then
        rm -f "$(last_file_path "$ev_id")" 2>/dev/null || true
        rm -f "$(pending_file_path "$ev_id")" 2>/dev/null || true
        continue
    fi

    now_ms=$(date +%s%3N)
    printf '%s' "$now_ms" > "$(pending_file_path "$ev_id")"
    (
        sleep "${SLEEP_DEBOUNCE}"
        pending_f="$(pending_file_path "$ev_id")"
        if [[ ! -f $pending_f ]]; then
            exit 0
        fi
        pending_ts=$(cat "$pending_f" 2>/dev/null || echo 0)
        now2=$(date +%s%3N)
        if [[ -z $pending_ts || $pending_ts -eq 0 ]]; then
            exit 0
        fi
        if [[ $((now2 - pending_ts)) -lt $DEBOUNCE_MS ]]; then
            exit 0
        fi
        rm -f "$pending_f" 2>/dev/null || true
        last=$(get_last_ms "$ev_id" || echo 0)
        now3=$(date +%s%3N)
        if [[ -n $last && $last -gt 0 && $((now3 - last)) -lt $COOLDOWN_MS ]]; then
            exit 0
        fi
        cur=$(get_volume "$ev_id" 2>/dev/null || true)
        if [[ -z $cur ]]; then
            pactl set-sink-input-volume "$ev_id" "$VOL_PCT" >/dev/null 2>&1 || true
            set_last_ms "$ev_id"
            exit 0
        fi
        if needs_set_volume "$ev_id"; then
            pactl set-sink-input-volume "$ev_id" "$VOL_PCT" >/dev/null 2>&1 || true
            set_last_ms "$ev_id"
        fi
    ) &
done

