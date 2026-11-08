#!/usr/bin/env bash
set -euo pipefail

CLIENT="${1:-}"
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run as root"
[[ -n "$CLIENT" ]] || die "Usage: $0 <client-name>"

EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_DIR="/etc/openvpn/server"
cd "$EASYRSA_DIR"
[[ -f "pki/issued/${CLIENT}.crt" ]] || die "Client '${CLIENT}' not found"

EASYRSA_BATCH=1 ./easyrsa revoke "$CLIENT"
./easyrsa gen-crl >/dev/null
cp pki/crl.pem "$SERVER_DIR/crl.pem"
chmod 644 "$SERVER_DIR/crl.pem"

if systemctl list-unit-files 2>/dev/null | grep -q '^openvpn-server@'; then
  systemctl restart openvpn-server@server
else
  systemctl restart openvpn@server
fi

rm -f "/root/${CLIENT}.ovpn"
echo "Revoked '${CLIENT}' and removed /root/${CLIENT}.ovpn"
