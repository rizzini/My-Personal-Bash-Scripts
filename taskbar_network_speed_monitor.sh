#!/bin/bash
interface='enp1s0'

if_status="$(ip a show "$interface" | awk 'NR == 1 {print $9; exit}')"

# script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# history_file="$script_dir/.taskbar_change_route_isp.txt"
# history_file_boot="$script_dir/.taskbar_change_route_isp_boot.txt"

# new_route_tmp="/tmp/getting_new_route.tmp"

# if [ "$1" == 'startup_apply_last_used_route' ]; then
#     history="$(< "$history_file_boot")"
#
#     # Configuração da tabela TIM
#     ip route add 192.168.1.0/24 dev "$interface" table tim
#     ip route add default via 192.168.1.1 table tim
#
#     # Configuração da tabela VIVO
#     ip route add 192.168.15.0/24 dev "$interface" table vivo
#     ip route add default via 192.168.15.1 table vivo
#
#     #Policy Rules
#     ip rule add from 192.168.1.141 table tim
#     ip rule add from 192.168.15.199 table vivo
#
#     ip route replace default via "$history"
#
#     exit
# elif [ "$1" == 'click' ]; then
#
#     current="$(ip route show default | awk '{print $3}')"
#     old="$(< "$history_file")"
#
#     if [ "$current" != "$old" ] || [ -f "$new_route_tmp" ]; then
#         if [ "$current" = '192.168.1.1' ]; then
#             sudo ip route replace default via 192.168.15.1
#             echo "$current" > "$history_file"
#             echo "$old" > "$history_file_boot"
#
#         elif [ "$current" = '192.168.15.1' ]; then
#             sudo ip route replace default via 192.168.1.1
#             echo "$current" > "$history_file"
#             echo "$old" > "$history_file_boot"
#
#         elif [ -f "$new_route_tmp" ]; then
#             if [ "$old" = '192.168.1.1' ]; then
#                 sudo ip route replace default via '192.168.15.1'
#                 rm -f "$new_route_tmp"
#                 notify-send -i network-wired "Rede" "Rota restabelecida usando script taskbar_network_speed_monitor.sh"
#
#             elif [ "$old" = '192.168.15.1' ]; then
#                 sudo ip route replace default via '192.168.1.1'
#                 rm -f "$new_route_tmp"
#                 notify-send -i network-wired "Rede" "Rota restabelecida usando script taskbar_network_speed_monitor.sh"
#
#             fi
#
#         fi
#
#     fi
#     exit
# fi

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

    # route="$(ip route show default | awk '{print $3}')"
    # if [ "$route" == '192.168.1.1' ]; then
    #     ISP_str='TIM'
    # elif [ "$route" == '192.168.15.1' ]; then
    #     ISP_str='VIVO'
    # elif [ "$if_status" != 'UP' ]; then
    #     ISP_str="$interface DOWN"
    # elif [ -z "$route" ]; then
    #     ISP_str="NO ROUTE"
    #     if [ ! -f "$new_route_tmp" ];then
    #         touch "$new_route_tmp"
    #         bash "$0" 'click' #get new route
    #
    #     fi
    # else
    #     ISP_str='UNKOWN'
    # fi

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
