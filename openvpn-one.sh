#!/usr/bin/env bash
set -euo pipefail

CLIENT_NAME="${1:-client1}"
SERVER_IP="${2:-}"
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
[[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "Client name: letters, digits, _ and - only"

install_server() {
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

  local easyrsa_bin
  easyrsa_bin="$(command -v easyrsa || true)"
  [[ -n "$easyrsa_bin" ]] || easyrsa_bin="/usr/share/easy-rsa/easyrsa"
  [[ -f "$easyrsa_bin" ]] || die "easyrsa not found"

  log "Preparing PKI in $EASYRSA_DIR"
  rm -rf "$EASYRSA_DIR"
  mkdir -p "$EASYRSA_DIR"
  if [[ -d /usr/share/easy-rsa ]]; then
    cp -r /usr/share/easy-rsa/. "$EASYRSA_DIR/"
  else
    cp -r "$(dirname "$(readlink -f "$easyrsa_bin")")/." "$EASYRSA_DIR/"
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

  local run_user run_group
  run_user="nobody"
  run_group="nogroup"
  getent group nogroup >/dev/null 2>&1 || run_group="nobody"

  local ovpn_ver ovpn_major ovpn_minor cipher_lines
  ovpn_ver="$(openvpn --version | head -1 | awk '{print $2}')"
  ovpn_major="${ovpn_ver%%.*}"
  ovpn_minor="$(printf '%s' "$ovpn_ver" | cut -d. -f2)"
  cipher_lines="data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC"
  if [[ "$ovpn_major" -lt 2 ]] || { [[ "$ovpn_major" -eq 2 ]] && [[ "$ovpn_minor" -lt 5 ]]; }; then
    cipher_lines="ncp-ciphers AES-256-GCM:AES-128-GCM
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
$cipher_lines
auth SHA256
user $run_user
group $run_group
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

  [[ -e /etc/openvpn/server.conf ]] || ln -s "$SERVER_DIR/server.conf" /etc/openvpn/server.conf

  log "Enabling IP forwarding"
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-openvpn.conf
  sysctl --system >/dev/null

  local wan_if
  wan_if="$(ip -4 route show default | awk '{print $5; exit}')"
  [[ -n "$wan_if" ]] || die "Cannot detect default network interface"

  log "Configuring NAT on $wan_if"
  add_rule() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
  add_nat()  { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }

  add_rule INPUT -i "$wan_if" -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT
  add_nat POSTROUTING -s "$VPN_CIDR" -o "$wan_if" -j MASQUERADE
  add_rule FORWARD -i tun0 -o "$wan_if" -j ACCEPT
  add_rule FORWARD -i "$wan_if" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

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
}

make_client() {
  local conf="$SERVER_DIR/server.conf"
  [[ -f "$conf" ]] || die "Server config not found: $conf"

  local port proto
  port="$(awk '$1=="port"{print $2; exit}' "$conf")"
  proto="$(awk '$1=="proto"{print $2; exit}' "$conf")"
  port="${port:-1194}"
  proto="${proto:-udp}"

  local ip="$SERVER_IP"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
  fi
  [[ -n "$ip" ]] || die "Cannot detect public IP, pass it as 2nd argument"

  cd "$EASYRSA_DIR"
  [[ -f "pki/issued/${CLIENT_NAME}.crt" ]] || {
    log "Creating certificate for '${CLIENT_NAME}'"
    EASYRSA_BATCH=1 ./easyrsa build-client-full "$CLIENT_NAME" nopass >/dev/null
  }

  local ovpn_ver ovpn_major ovpn_minor cipher_lines
  ovpn_ver="$(openvpn --version | head -1 | awk '{print $2}')"
  ovpn_major="${ovpn_ver%%.*}"
  ovpn_minor="$(printf '%s' "$ovpn_ver" | cut -d. -f2)"
  cipher_lines="data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC"
  if [[ "$ovpn_major" -lt 2 ]] || { [[ "$ovpn_major" -eq 2 ]] && [[ "$ovpn_minor" -lt 5 ]]; }; then
    cipher_lines="ncp-ciphers AES-256-GCM:AES-128-GCM
cipher AES-256-CBC"
  fi

  local out="/root/${CLIENT_NAME}.ovpn"
  log "Building $out"
  {
    echo "client"
    echo "dev tun"
    echo "proto $proto"
    echo "remote $ip $port"
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "auth SHA256"
    echo "auth-nocache"
    echo "$cipher_lines"
    echo "verb 3"
    echo "<ca>"
    cat pki/ca.crt
    echo "</ca>"
    echo "<cert>"
    cat "pki/issued/${CLIENT_NAME}.crt"
    echo "</cert>"
    echo "<key>"
    cat "pki/private/${CLIENT_NAME}.key"
    echo "</key>"
    echo "<tls-crypt>"
    cat ta.key
    echo "</tls-crypt>"
  } > "$out"
  chmod 600 "$out"

  cat <<EOF

OpenVPN ready.
  Endpoint : ${ip}:${port}/${proto}
  Client   : ${out}
  Status   : systemctl status openvpn-server@${SERVER_NAME}

Import ${out} into the OpenVPN client app.
EOF
}

if [[ -f "$SERVER_DIR/server.conf" ]]; then
  log "OpenVPN server already installed, skipping install"
else
  install_server
fi
make_client
