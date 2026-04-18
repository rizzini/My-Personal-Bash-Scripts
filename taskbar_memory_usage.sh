#!/bin/sh
swaps=$(< /proc/swaps)
enable_zram() {
    swapoff -a
    echo 0 > /sys/module/zswap/parameters/enabled
    if ! lsmod | grep -q "^zram"; then
        modprobe zram num_devices=1 max_comp_streams=4
    fi
    echo zstd > /sys/block/zram0/comp_algorithm
    echo 4G > /sys/block/zram0/disksize
    mkswap -U clear /dev/zram0
    swapon --discard --priority 100 /dev/zram0
    swapon --priority 1 /dev/sda8
    sysctl -w vm.watermark_boost_factor=0 vm.watermark_scale_factor=100 vm.page-cluster=0 vm.swappiness=10 vm.vfs_cache_pressure=50
}
disable_zram() {
    for s in $(awk 'NR>1 {print $1}' /proc/swaps); do
        swapoff "$s" || { notify-send -u critical "Failed to swapoff $s"; return 1; }
    done
    sysctl -w vm.watermark_boost_factor=15000 vm.watermark_scale_factor=10 vm.page-cluster=3 vm.swappiness=60 vm.vfs_cache_pressure=100
    echo 1 > /sys/module/zswap/parameters/enabled
    while ! modprobe -r zram; do
        sleep 0.5;
    done
}

if [ "$1" == 'click' ]; then
    if [[ "$swaps" != *"/dev/zram0"* ]]; then
        enable_zram
        exit
    else
        disable_zram
        exit
    fi

elif [ "$1" == 'startup' ]; then
    enable_zram
    exit
fi

adjust_unit() {
    local scale=1024
    local units=("KB" "MB" "GB")
    local unit=0
    local value=${1:-0}
    local original_value=$value
    while (( value >= scale && unit < ${#units[@]} - 1 )); do
        value=$((value / scale))
        ((unit++))
    done

    if [[ "${units[unit]}" == "GB" ]]; then
        value_gb=$(echo "scale=2; $original_value / ($scale ^ $unit)" | bc)
        echo "${value_gb}${units[unit]}"
    else
        echo "${value}${units[unit]}"
    fi
}
while read -r key val _; do
    case "$key" in
        "MemTotal:") mem_total=$val ;;
        "MemFree:") mem_free=$val ;;
        "Buffers:") buffers=$val ;;
        "Cached:") cached=$val ;;
        "SReclaimable:") sreclaimable=$val ;;
        "Shmem:") shmem=$val ;;
    esac
done < /proc/meminfo

swap_used_zram_total=0
swap_used_disk_total=0
while read -r name _ _ used _; do
    if [[ "$name" == /dev/zram* ]]; then
        swap_used_zram_total=$((swap_used_zram_total + used))
    else
        swap_used_disk_total=$((swap_used_disk_total + used))
    fi
done < /proc/swaps

mem_used=$((mem_total - mem_free - buffers - cached - sreclaimable + shmem))
mem_used_mb=$((mem_used / 1024))
if ((mem_used_mb >= 1024)); then
    mem_used_gb=$(echo "scale=2; $mem_used_mb / 1024" | bc)
    if (( $(echo "$mem_used_gb > 4.5" | bc -l) )) && (( $(echo "$mem_used_gb < 5" | bc -l) )); then
        mem_used_gb_colored="\e[93m${mem_used_gb}GB\e[0m"
    elif (( $(echo "$mem_used_gb > 5" | bc -l) )); then
        mem_used_gb_colored="\e[91m${mem_used_gb}GB\e[0m"
    else
        mem_used_gb_colored="${mem_used_gb}GB"
    fi
else
    mem_used_gb_colored="${mem_used_mb}MB"
fi

output="Mem: $mem_used_gb_colored"
if [[ "$swaps" == *"/dev/zram0"* ]]; then
    swap_used_zram_total_if=$((swap_used_zram_total - 12000))
        if [ $swap_used_zram_total_if -gt  1048576 ] && [ $swap_used_zram_total_if -lt  2097152 ]; then
            output="$output / ZRAM: \e[93m$(adjust_unit "$swap_used_zram_total")\e[0m"
        elif [ $swap_used_zram_total_if -gt  2097152 ]; then
            output="$output / ZRAM: \e[91m$(adjust_unit "$swap_used_zram_total")\e[0m"
        else
            output="$output / ZRAM: $(adjust_unit "$swap_used_zram_total")"
        fi
    if (( swap_used_disk_total > 0 )); then
        output="$output / Disco: $(adjust_unit "$swap_used_disk_total")"
    fi
else
    output="$output / \e[91mOFF\e[0m"
fi
printf "%b\n" "$output"

ps -eo comm=,rss= | awk '$1!="plasma-browser-" && $1!="plasmashell" && $1!="kwin_wayland" && $1!="fish" && $1!="ps" && $1 !~ /^kworker\// {mem[$1] += $2} END {for (p in mem) printf "%s -> %.1f MiB\n", p, mem[p]/1024}'| sort -k3 -nr | head -n 5 > "/tmp/taskbar_memory_usage_hover"
