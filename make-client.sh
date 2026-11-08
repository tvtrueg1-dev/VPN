#!/usr/bin/env bash
set -euo pipefail

CLIENT="${1:-}"
SERVER_IP="${2:-}"

die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run as root"
[[ -n "$CLIENT" ]] || die "Usage: $0 <client-name> [server-public-ip]"
[[ "$CLIENT" =~ ^[A-Za-z0-9_-]+$ ]] || die "Client name: letters, digits, _ and - only"

EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_DIR="/etc/openvpn/server"
CONF="$SERVER_DIR/server.conf"
[[ -f "$CONF" ]] || die "Server config not found: $CONF (run install-openvpn-server.sh first)"

VPN_PORT="$(awk '$1=="port"{print $2; exit}' "$CONF")"
VPN_PROTO="$(awk '$1=="proto"{print $2; exit}' "$CONF")"
VPN_PORT="${VPN_PORT:-1194}"
VPN_PROTO="${VPN_PROTO:-udp}"

if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
fi
[[ -n "$SERVER_IP" ]] || die "Cannot detect public IP, pass it as 2nd argument"

cd "$EASYRSA_DIR"
[[ -f "pki/issued/${CLIENT}.crt" ]] && die "Client '${CLIENT}' already exists"

log "Creating certificate for '${CLIENT}'"
EASYRSA_BATCH=1 ./easyrsa build-client-full "$CLIENT" nopass >/dev/null

OVPN_VER="$(openvpn --version | head -1 | awk '{print $2}')"
OVPN_MAJOR="${OVPN_VER%%.*}"
OVPN_MINOR="$(printf '%s' "$OVPN_VER" | cut -d. -f2)"
CIPHER_LINES="data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC"
if [[ "$OVPN_MAJOR" -lt 2 ]] || { [[ "$OVPN_MAJOR" -eq 2 ]] && [[ "$OVPN_MINOR" -lt 5 ]]; }; then
  CIPHER_LINES="ncp-ciphers AES-256-GCM:AES-128-GCM
cipher AES-256-CBC"
fi

OUT="/root/${CLIENT}.ovpn"
log "Building $OUT"

{
  echo "client"
  echo "dev tun"
  echo "proto $VPN_PROTO"
  echo "remote $SERVER_IP $VPN_PORT"
  echo "resolv-retry infinite"
  echo "nobind"
  echo "persist-key"
  echo "persist-tun"
  echo "remote-cert-tls server"
  echo "auth SHA256"
  echo "auth-nocache"
  echo "$CIPHER_LINES"
  echo "verb 3"
  echo "<ca>"
  cat pki/ca.crt
  echo "</ca>"
  echo "<cert>"
  cat "pki/issued/${CLIENT}.crt"
  echo "</cert>"
  echo "<key>"
  cat "pki/private/${CLIENT}.key"
  echo "</key>"
  echo "<tls-crypt>"
  cat ta.key
  echo "</tls-crypt>"
} > "$OUT"

chmod 600 "$OUT"

cat <<EOF

Client profile created: $OUT
Import this .ovpn file into the OpenVPN client app (Windows/macOS/iOS/Android/Linux).
Endpoint: ${SERVER_IP}:${VPN_PORT}/${VPN_PROTO}
EOF
