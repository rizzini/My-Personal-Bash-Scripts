#!/bin/bash
interface='enp1s0'

if_status="$(ip a show "$interface" | awk 'NR == 1 {print $9; exit}')"

convert_units() {
    local unit_mode=$1
    local is_speed=$2
    local bytes=$3
    local value unit
    local suffix=""

    if [ "$is_speed" -eq 1 ]; then
        suffix="/s"
    fi

    case "$unit_mode" in
        1)
            value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024 }")
            unit="KB"
            ;;
        2)
            value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024/1024 }")
            unit="MB"
            ;;
        3)
            if (( bytes >= 1024*1024*1024 )); then
                value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024/1024/1024 }")
                unit="GB"
            elif (( bytes >= 1024*1024 )); then
                value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024/1024 }")
                unit="MB"

            else
                value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024 }")
                unit="KB"
            fi
            ;;
    esac
    echo "${value}${unit}${suffix}"
}
format_uptime() {
    local up total_days hours minutes
    up=$(cut -d. -f1 /proc/uptime)

    total_days=$((up / 86400))
    hours=$(((up % 86400) / 3600))
    minutes=$(((up % 3600) / 60))

    if [ "$total_days" -gt 0 ]; then
        printf "%dd %02dh %02dm" "$total_days" "$hours" "$minutes"
    else
        printf "%02dh %02dm" "$hours" "$minutes"
    fi
}

cache="/tmp/taskbar_network_speed_monitor_$interface"
hover_interval=1
if [ "$1" = "hover" ]; then
    now=$(date +%s)
    if [ -f "$cache" ]; then
        read -r last_ts < "$cache"
        if [ $((now - last_ts)) -lt "$hover_interval" ]; then
            tail -n +2 "$cache"
            exit 0
        fi
    fi
   read -r rx tx < <(awk -v i="$interface" '$1==i":" {print $2, $10}' /proc/net/dev)

    uptime_str=$(format_uptime)

    output="+Total+ | Uptime: $uptime_str
Download: $(convert_units 3 0 "$rx") | Upload: $(convert_units 3 0 "$tx")"

    printf '%s\n%s\n' "$now" "$output" > "$cache"
    printf '%s\n' "$output"
    exit 0
fi

get_data() {
    local iface="$1"
    while IFS= read -r line; do
        dev="${line%%:*}"
        dev="${dev// /}"
        if [[ "$dev" == "$iface" ]]; then
            data="${line#*:}"
            read -ra fields <<< "$data"
            rx="${fields[0]}"
            tx="${fields[8]}"
            echo "$rx $tx"
            return
        fi
    done < /proc/net/dev
}

colorize_speed() {
    local speed_str="$1"
    local color_reset="\e[0m"
    local color_green="\e[92m"
    local color_yellow="\e[93m"
    local color_red="\e[91m"
    local value
    value=$(echo "$speed_str" | awk -F'MB/s' '{print $1}')
    value=$(echo "$value" | tr ',' '.' | xargs)
    if (( $(echo "$value >= 2 && $value <= 25" | bc -l) )); then
        echo -e "${color_green}${speed_str}${color_reset}"
    elif (( $(echo "$value >= 25 && $value <= 50" | bc -l) )); then
        echo -e "${color_yellow}${speed_str}${color_reset}"
    elif (( $(echo "$value > 50" | bc -l) )); then
        echo -e "${color_red}${speed_str}${color_reset}"
    else
        echo "$speed_str"
    fi
}

IFS=' ' read -r rx1 tx1 <<< "$(get_data "$interface")"
sleep 1
IFS=' ' read -r rx2 tx2 <<< "$(get_data "$interface")"

rx_original=$((rx2 - rx1))
tx_original=$((tx2 - tx1))

rx_converted=$(convert_units 2 1 "$rx_original")
tx_converted=$(convert_units 2 1 "$tx_original")

rx_converted=$(colorize_speed "$rx_converted")
tx_converted=$(colorize_speed "$tx_converted")

if [ "$if_status" != 'UP' ]; then
    echo -e "\e[95m\033[1m${interface} DOWN\e[0m"
else
    echo -e " $rx_converted |  $tx_converted"
fi
