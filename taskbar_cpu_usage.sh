#!/bin/bash
get_cpu_values() {
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
    echo "$idle $total"
}
read -r idle1 total1 < <(get_cpu_values)
sleep 0.5
read -r idle2 total2 < <(get_cpu_values)
delta_idle=$((idle2 - idle1))
delta_total=$((total2 - total1))
cpu_usage=$((100 * (delta_total - delta_idle) / delta_total))
if ((cpu_usage > 70)); then
    printf " \e[91m %s%%\e[0m\n" "$cpu_usage"
else
    printf " %s%%" "$cpu_usage"
fi

stamp_file="/tmp/.taskbar_cpu_usage_last_run"
now=$(date +%s)
if [[ ! -f "$stamp_file" ]] || (( now > $(cat "$stamp_file") )); then
    echo $((now + 1)) > "$stamp_file"
    ps -eo comm=,pcpu= --sort=-pcpu | awk '$1!="chrome" && $1!="easyeffects" && $1!="fish" && $1!="ps" && $1!="kwin_wayland" && $1!="Xwayland" && $1 !~ /^kworker\// {printf "%s -> %.1f%%\n", $1, $2}' | head -n 5 > /tmp/taskbar_cpu_usage_hover
fi

