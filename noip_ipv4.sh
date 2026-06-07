#!/bin/bash

cache="$HOME/.cache/noip_ip"
mkdir -p "$(dirname "$cache")"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t creds < <(
    gpg --decrypt -q "$script_dir/noip_senha.gpg" | sed '/^$/d'
)

host="${creds[0]}"
user="${creds[1]}"
password="${creds[2]}"

ip4="$(curl -4fsS https://ifconfig.me)"

if [[ -z "$ip4" ]]; then
    notify-send -u critical -i network-wired "No-IP updater" "Erro ao pegar o IP IPv4."
    exit 1
fi

cached_ip=""

if [[ -f "$cache" ]]; then
    cached_ip="$(<"$cache")"
fi

if [[ "$ip4" == "$cached_ip" ]]; then
    exit 0
fi

response="$(curl -fsS --user "${user}:${password}" "https://dynupdate.no-ip.com/nic/update?hostname=${host}&myip=${ip4}")"

if [[ "$response" == *"good"* || "$response" == *"nochg"* ]]; then
    printf '%s\n' "$ip4" > "$cache"
    exit 0
fi

notify-send -u critical -i network-wired "No-IP updater" "Falha ao atualizar No-IP: ${response}"

exit 1
