#!/bin/bash

cache="$HOME/.cache/noip_ips"
interface="enp1s0"

mkdir -p "$(dirname "$cache")"

ip6=$(ip -6 addr show dev "$interface" | grep 'scope global' | grep '/128' | awk '{print $2}' | cut -d/ -f1 | head -n1)

if [[ -z "$ip6" ]]; then
    ip6=$(ip -6 addr show dev "$interface" | grep 'scope global' | grep '/64' | grep -v 'temporary' | awk '{print $2}' | cut -d/ -f1 | head -n1)
fi

if [[ -z "$ip6" ]]; then
    notify-send -u critical -i network-wired "No-IP IPv6 updater" "Erro ao pegar o IP IPv6."
    exit 1
fi

ip4="$(curl -4 -s ifconfig.me)"

if [[ -z "$ip4" ]]; then
    notify-send -u critical -i network-wired "No-IP IPv6 updater" "Erro ao pegar o IP IPv4."
    exit 1
fi

cached_ip6=""
cached_ip4=""

if [ -f "$cache" ]; then
    mapfile -t cache_data < "$cache"

    cached_ip6="${cache_data[0]}"
    cached_ip4="${cache_data[1]}"
fi

if [[ "$ip6" == "$cached_ip6" && "$ip4" == "$cached_ip4" ]]; then
    exit 0
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t creds < <(gpg --decrypt -q "$script_dir/noip_ipv6.senha.gpg" | sed '/^$/d')

host="${creds[0]}"
user="${creds[1]}"
password="${creds[2]}"

status=0

if ! "$HOME/scripts/update_dmz_addr.py" -6 "$ip6" >/dev/null; then
    notify-send -u critical -i network-wired "No-IP IPv6 updater" "Erro ao configurar DMZ."
    status=1
fi

update6="$(curl -s "https://dynupdate.no-ip.com/nic/update?hostname=${host}&myip=${ip6}" --user "${user}:${password}")"

if [[ "$update6" != *"nochg"* && "$update6" != *"good"* ]]; then
    status=1
fi

update4="$(curl -s "https://dynupdate.no-ip.com/nic/update?hostname=${host}&myip=${ip4}"  --user "${user}:${password}")"

if [[ "$update4" != *"nochg"* && "$update4" != *"good"* ]]; then
    status=1
fi

if [ "$status" -eq 0 ]; then
    printf '%s\n%s\n' "$ip6" "$ip4" > "$cache"
fi

exit "$status"
