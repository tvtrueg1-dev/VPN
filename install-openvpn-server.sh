#!/usr/bin/env bash
set -euo pipefail

VPN_PORT="${VPN_PORT:-1194}"
VPN_PROTO="${VPN_PROTO:-udp}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_NETMASK="${VPN_NETMASK:-255.255.255.0}"
VPN_CIDR="${VPN_CIDR:-10.8.0.0/24}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
SERVER_NAME="${SERVER_NAME:-server}"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_DIR="/etc/openvpn/server"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run as root"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openvpn easy-rsa iptables iptables-persistent curl openssl
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y openvpn easy-rsa iptables-services curl openssl
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y openvpn easy-rsa iptables-services curl openssl
else
  die "Unsupported distro (need apt/dnf/yum)"
fi

command -v openvpn >/dev/null 2>&1 || die "openvpn not installed"
command -v ip >/dev/null 2>&1 || die "iproute2 (ip) not installed"

EASYRSA_BIN="$(command -v easyrsa || true)"
[[ -n "$EASYRSA_BIN" ]] || EASYRSA_BIN="/usr/share/easy-rsa/easyrsa"
[[ -f "$EASYRSA_BIN" ]] || die "easyrsa not found"

log "Preparing PKI in $EASYRSA_DIR"
rm -rf "$EASYRSA_DIR"
mkdir -p "$EASYRSA_DIR"
if [[ -d /usr/share/easy-rsa ]]; then
  cp -r /usr/share/easy-rsa/. "$EASYRSA_DIR/"
else
  cp -r "$(dirname "$(readlink -f "$EASYRSA_BIN")")/." "$EASYRSA_DIR/"
fi

cd "$EASYRSA_DIR"
./easyrsa init-pki >/dev/null
EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenVPN-CA" ./easyrsa build-ca nopass >/dev/null
EASYRSA_BATCH=1 ./easyrsa gen-req "$SERVER_NAME" nopass >/dev/null
EASYRSA_BATCH=1 ./easyrsa sign-req server "$SERVER_NAME" >/dev/null
./easyrsa gen-dh >/dev/null
./easyrsa gen-crl >/dev/null

log "Generating tls-crypt key"
if ! openvpn --genkey secret "$EASYRSA_DIR/ta.key" >/dev/null 2>&1; then
  openvpn --genkey --secret "$EASYRSA_DIR/ta.key"
fi

log "Installing server files into $SERVER_DIR"
mkdir -p "$SERVER_DIR"
cp pki/ca.crt "pki/issued/${SERVER_NAME}.crt" "pki/private/${SERVER_NAME}.key" \
   pki/dh.pem pki/crl.pem ta.key "$SERVER_DIR/"
chmod 600 "$SERVER_DIR/${SERVER_NAME}.key" "$SERVER_DIR/ta.key"
chmod 644 "$SERVER_DIR/crl.pem"

RUN_USER="nobody"
RUN_GROUP="nogroup"
getent group nogroup >/dev/null 2>&1 || RUN_GROUP="nobody"

OVPN_VER="$(openvpn --version | head -1 | awk '{print $2}')"
OVPN_MAJOR="${OVPN_VER%%.*}"
OVPN_MINOR="$(printf '%s' "$OVPN_VER" | cut -d. -f2)"
CIPHER_LINES="data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC"
if [[ "$OVPN_MAJOR" -lt 2 ]] || { [[ "$OVPN_MAJOR" -eq 2 ]] && [[ "$OVPN_MINOR" -lt 5 ]]; }; then
  CIPHER_LINES="ncp-ciphers AES-256-GCM:AES-128-GCM
cipher AES-256-CBC"
fi

log "Writing $SERVER_DIR/server.conf"
cat > "$SERVER_DIR/server.conf" <<EOF
port $VPN_PORT
proto $VPN_PROTO
dev tun
topology subnet
ca ca.crt
cert ${SERVER_NAME}.crt
key ${SERVER_NAME}.key
dh dh.pem
tls-crypt ta.key
crl-verify crl.pem
server $VPN_SUBNET $VPN_NETMASK
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"
keepalive 10 120
$CIPHER_LINES
auth SHA256
user $RUN_USER
group $RUN_GROUP
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

if [[ ! -e /etc/openvpn/server.conf ]]; then
  ln -s "$SERVER_DIR/server.conf" /etc/openvpn/server.conf
fi

log "Enabling IP forwarding"
cat > /etc/sysctl.d/99-openvpn.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n "$WAN_IF" ]] || die "Cannot detect default network interface"

log "Configuring NAT on $WAN_IF"
add_rule() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
add_nat()  { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }

add_rule INPUT -i "$WAN_IF" -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT
add_nat POSTROUTING -s "$VPN_CIDR" -o "$WAN_IF" -j MASQUERADE
add_rule FORWARD -i tun0 -o "$WAN_IF" -j ACCEPT
add_rule FORWARD -i "$WAN_IF" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$VPN_PORT/$VPN_PROTO" >/dev/null
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw reload >/dev/null
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null
elif command -v service >/dev/null 2>&1 && [[ -f /etc/sysconfig/iptables ]]; then
  service iptables save >/dev/null 2>&1 || true
fi

log "Starting OpenVPN service"
systemctl daemon-reload 2>/dev/null || true
if systemctl list-unit-files 2>/dev/null | grep -q '^openvpn-server@'; then
  systemctl enable --now "openvpn-server@${SERVER_NAME}"
else
  systemctl enable --now "openvpn@${SERVER_NAME}"
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="<YOUR_SERVER_IP>"

cat <<EOF

OpenVPN server is ready.
  Endpoint : ${PUBLIC_IP}:${VPN_PORT}/${VPN_PROTO}
  Subnet   : ${VPN_CIDR}
  Status   : systemctl status openvpn-server@${SERVER_NAME}

Create a client:
  sudo /root/openvpn-setup/make-client.sh myphone ${PUBLIC_IP}

Revoke a client:
  sudo /root/openvpn-setup/revoke-client.sh myphone
EOF
