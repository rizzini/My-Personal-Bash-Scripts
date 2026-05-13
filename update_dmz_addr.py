#!/usr/bin/env python3
# made 100% by AI
import requests
import hashlib
import binascii
import sys
import time
import argparse
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

PASSWORD_FILE = SCRIPT_DIR / "update_dmz_addr.senha.gpg"

def load_credentials():
    try:
        result = subprocess.run(
            [
                "gpg",
                "--quiet",
                "--decrypt",
                str(PASSWORD_FILE)
            ],
            capture_output=True,
            text=True,
            check=True
        )

        lines = result.stdout.strip().splitlines()

        if len(lines) < 2:
            print("[-] Arquivo deve conter login e senha")
            sys.exit(1)

        username = lines[0].strip()
        password = lines[1].strip()

        return username, password

    except subprocess.CalledProcessError as e:
        print("[-] Erro ao decriptografar credenciais")
        print(e.stderr)
        sys.exit(1)


parser = argparse.ArgumentParser()

parser.add_argument(
    "-4",
    "--ipv4",
    required=False,
    help="Endereço IPv4 da DMZ"
)

parser.add_argument(
    "-6",
    "--ipv6",
    required=True,
    default="0:0:0:0:0:0:0:0",
    help="Endereço IPv6 da DMZ"
)

args = parser.parse_args()

DMZ_IP = args.ipv4
DMZ_IPV6 = args.ipv6

BASE_URL = "http://192.168.0.1"

USERNAME, PASSWORD = load_credentials()

session = requests.Session()

COMMON_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/148.0.0.0 Safari/537.36"
    ),
    "X-Requested-With": "XMLHttpRequest",
    "Referer": f"{BASE_URL}/",
    "Origin": BASE_URL,
    "Accept": "*/*",
}

session.headers.update(COMMON_HEADERS)

def pbkdf2_hex(password, salt):
    dk = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode(),
        salt.encode(),
        1000,
        16
    )
    return binascii.hexlify(dk).decode()

print("[+] Solicitando salts...")

r = session.post(
    f"{BASE_URL}/api/v1/session/login",
    data={
        "username": USERNAME,
        "password": "seeksalthash"
    }
)

print("[+] Status:", r.status_code)
print("[+] Resposta:", r.text)

data = r.json()

if data.get("error") != "ok":
    print("[-] Erro ao obter salts")
    sys.exit(1)

salt = data.get("salt")
saltwebui = data.get("saltwebui")

print("[+] salt:", salt)
print("[+] saltwebui:", saltwebui)

if salt == "none":
    final_password = PASSWORD
else:
    hashed1 = pbkdf2_hex(PASSWORD, salt)
    final_password = pbkdf2_hex(hashed1, saltwebui)

print("[+] Hash final:", final_password)

print("[+] Fazendo login real...")

r2 = session.post(
    f"{BASE_URL}/api/v1/session/login",
    data={
        "username": USERNAME,
        "password": final_password
    }
)

print("[+] Status login:", r2.status_code)
print("[+] Resposta login:", r2.text)

if '"error":"ok"' not in r2.text.replace(" ", ""):
    print("[-] Falha no login")
    sys.exit(1)

print("[+] Login efetuado com sucesso")

print("[+] Cookies:")
for c in session.cookies:
    print("   ", c.name, "=", c.value)

auth_token = session.cookies.get("auth")

if not auth_token:
    print("[-] Cookie auth não encontrado")
    sys.exit(1)

print("[+] Token auth:", auth_token)

session.headers.update({
    "X-CSRF-TOKEN": auth_token
})

print("[+] Abrindo index...")

r_index = session.get(f"{BASE_URL}/")

print("[+] index:", r_index.status_code)

print("[+] Carregando session/menu...")

r_menu = session.get(
    f"{BASE_URL}/api/v1/session/menu"
)

print("[+] menu status:", r_menu.status_code)

print("[+] Abrindo página DMZ...")

r_page = session.get(
    f"{BASE_URL}/views/app_dmz.html"
)

print("[+] app_dmz.html:", r_page.status_code)

print("[+] Consultando configuração atual da DMZ...")

timestamp = int(time.time() * 1000)

r_dmz = session.get(
    f"{BASE_URL}/api/v1/dmz?_={timestamp}"
)

print("[+] Status:", r_dmz.status_code)
print("[+] Resposta:")
print(r_dmz.text)

if r_dmz.status_code != 200:
    print("[-] Sem permissão para acessar DMZ")
    sys.exit(1)

msg = "[+] Ativando DMZ para:"

if DMZ_IP:
    msg += f" {DMZ_IP}"

if DMZ_IP and DMZ_IPV6:
    msg += " e"

if DMZ_IPV6:
    msg += f" {DMZ_IPV6}"

print(msg)

payload = {
    "enable": "true",
    "host": DMZ_IP,
    "hostv6": DMZ_IPV6
}

r_set = session.post(
    f"{BASE_URL}/api/v1/dmz",
    data=payload
)

print("[+] Status POST:", r_set.status_code)
print("[+] Resposta POST:")
print(r_set.text)

if '"error":"ok"' in r_set.text.replace(" ", ""):
    print("[+] DMZ configurada com sucesso")
else:
    print("[-] Falha ao configurar DMZ")
