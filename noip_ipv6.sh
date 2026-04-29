#!/bin/bash

cache="$HOME/.cache/noip_ipv6"
interface="enp1s0"

mkdir -p "$(dirname "$cache")"

ip=$(ip -6 addr show dev "$interface" | grep 'scope global' | grep '/128' | awk '{print $2}' | cut -d/ -f1)

if [ -z "$ip" ]; then
    notify-send -u critical -i network-wired "No-IP IPv6 updater" "Erro ao pegar o ip IPv6"
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t creds < <(gpg --decrypt -q "$script_dir/noip_ipv6.senha.gpg" | sed '/^$/d')

host="${creds[0]}"
user="${creds[1]}"
password="${creds[2]}"

if [ -f "$cache" ] && grep -q "$ip" "$cache"; then
    exit 0
fi

echo "$ip" > "$cache"

curl -s "https://dynupdate.no-ip.com/nic/update?hostname=${host}&myip=${ip}" --user "${user}:${password}"
