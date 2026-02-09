#!/bin/bash
###############################################################################
#  TUNNEL SERVER SETUP: AmneziaWG + OpenVPN over Cloak
#  Run on your SERVER (Ubuntu 20.04 / 22.04 / 24.04)
#  Usage:  sudo bash server-setup.sh
###############################################################################
set -euo pipefail

# ── Colors & helpers ─────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
line() { printf "${C}─────────────────────────────────────────────────${N}\n"; }
ok()   { printf "  ${G}✔${N} %s\n" "$1"; }
info() { printf "  ${C}ℹ${N} %s\n" "$1"; }
err()  { printf "  ${R}✖${N} %s\n" "$1"; }
step() { printf "\n${B}▶ [%s] %s${N}\n" "$1" "$2"; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo bash $0"; exit 1
fi

# ── Banner ───────────────────────────────────────────────────────────────────
clear
printf "${B}${C}"
cat << 'BANNER'

  ╔═══════════════════════════════════════════╗
  ║   🛡️  Tunnel Server Setup                ║
  ║   AmneziaWG + OpenVPN over Cloak         ║
  ╚═══════════════════════════════════════════╝

BANNER
printf "${N}"

# ── Interactive prompts ──────────────────────────────────────────────────────
# Auto-detect public IP (try multiple services, validate result)
detect_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://checkip.amazonaws.com" "https://ipinfo.io/ip" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]')
        # Validate it looks like an IPv4 address
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

DETECTED_IP=$(detect_ip)

if [[ -n "$DETECTED_IP" ]]; then
    printf "  ${G}Detected public IP:${N} ${B}%s${N}\n" "$DETECTED_IP"
    read -rp "  Use this IP? [Y/n]: " USE_DETECTED
    if [[ "${USE_DETECTED,,}" == "n" ]]; then
        read -rp "  Enter server public IP: " SERVER_PUBLIC_IP
    else
        SERVER_PUBLIC_IP="$DETECTED_IP"
    fi
else
    info "Could not auto-detect public IP."
    read -rp "  Enter server public IP: " SERVER_PUBLIC_IP
fi

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    err "No IP provided. Exiting."; exit 1
fi

echo ""
line
printf "  ${B}Server IP:${N} %s\n" "$SERVER_PUBLIC_IP"
line

# ── Defaults (no input needed) ───────────────────────────────────────────────
AWG_PORT=51820
CLOAK_PORT=443
OVPN_PORT=1194

AWG_SERVER_ADDR="10.10.10.1/24"
AWG_CLIENT_ADDR="10.10.10.2/32"
OVPN_SUBNET="10.20.20.0"
OVPN_MASK="255.255.255.0"

CLOAK_DISGUISE="www.bing.com"
CLOAK_VERSION="2.9.0"

JC=4; JMIN=40; JMAX=70
S1=0; S2=0
H1=1; H2=2; H3=3; H4=4

OUT_DIR="/root/tunnel-client-files"
mkdir -p "$OUT_DIR"

# ═════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════

step "1/7" "Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git pkg-config \
    openvpn easy-rsa wget net-tools iptables curl jq \
    linux-headers-$(uname -r) 2>/dev/null || true
ok "Base packages ready"

step "2/7" "Installing Go..."
if ! command -v go &>/dev/null || [[ $(go version 2>/dev/null | grep -oP '1\.\K\d+' || echo 0) -lt 21 ]]; then
    GO_VER="1.22.5"
    wget -q "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    ok "Go ${GO_VER} installed"
else
    ok "Go already installed"
fi
export PATH="/usr/local/go/bin:$PATH"

step "3/7" "Installing AmneziaWG..."
if ! command -v awg &>/dev/null; then
    rm -rf /tmp/amneziawg-tools
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
    make -C /tmp/amneziawg-tools/src -j"$(nproc)" -s
    make -C /tmp/amneziawg-tools/src install -s
    ok "amneziawg-tools installed"
else
    ok "amneziawg-tools already installed"
fi
if ! command -v amneziawg-go &>/dev/null && [[ ! -f /usr/local/bin/amneziawg-go ]]; then
    rm -rf /tmp/amneziawg-go
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
    cd /tmp/amneziawg-go
    make -j"$(nproc)" -s
    cp amneziawg-go /usr/local/bin/
    ok "amneziawg-go installed"
else
    ok "amneziawg-go already installed"
fi

step "4/7" "Installing Cloak v${CLOAK_VERSION}..."
if ! command -v ck-server &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-server-linux-amd64-v${CLOAK_VERSION}" \
        -O /usr/local/bin/ck-server
    chmod +x /usr/local/bin/ck-server
    ok "Cloak server installed"
else
    ok "Cloak server already installed"
fi

step "5/7" "Enabling IP forwarding..."
cat > /etc/sysctl.d/99-tunnel.conf <<SYSCTL
net.ipv4.ip_forward = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-tunnel.conf > /dev/null
ok "IP forwarding enabled"

# ═════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════

step "6/7" "Generating keys & configuring AmneziaWG..."
mkdir -p /etc/amnezia/amneziawg

AWG_SERVER_PRIVKEY=$(awg genkey)
AWG_SERVER_PUBKEY=$(echo "$AWG_SERVER_PRIVKEY" | awg pubkey)
AWG_CLIENT_PRIVKEY=$(awg genkey)
AWG_CLIENT_PUBKEY=$(echo "$AWG_CLIENT_PRIVKEY" | awg pubkey)
AWG_PSK=$(awg genpsk)

cat > /etc/amnezia/amneziawg/awg0.conf <<CONF
[Interface]
Address    = ${AWG_SERVER_ADDR}
ListenPort = ${AWG_PORT}
PrivateKey = ${AWG_SERVER_PRIVKEY}
Jc   = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey    = ${AWG_CLIENT_PUBKEY}
PresharedKey = ${AWG_PSK}
AllowedIPs   = ${AWG_CLIENT_ADDR}
CONF
chmod 600 /etc/amnezia/amneziawg/awg0.conf
ok "AmneziaWG configured"

step "7/7" "Configuring OpenVPN + Cloak..."
EASYRSA_DIR="/etc/openvpn/easy-rsa"
PKI_DIR="${EASYRSA_DIR}/pki"

rm -rf "$EASYRSA_DIR"
make-cadir "$EASYRSA_DIR"
cd "$EASYRSA_DIR"

cat > vars <<'VARS'
set_var EASYRSA_BATCH       "yes"
set_var EASYRSA_REQ_CN      "TunnelCA"
set_var EASYRSA_KEY_SIZE     2048
set_var EASYRSA_ALGO         ec
set_var EASYRSA_CURVE        secp384r1
set_var EASYRSA_DIGEST       "sha384"
set_var EASYRSA_CA_EXPIRE    3650
set_var EASYRSA_CERT_EXPIRE  3650
VARS

info "Generating PKI (this takes a moment)..."
./easyrsa init-pki          &>/dev/null
./easyrsa --batch build-ca nopass  &>/dev/null
./easyrsa --batch gen-req   server  nopass &>/dev/null
./easyrsa --batch sign-req  server  server &>/dev/null
./easyrsa --batch gen-req   client1 nopass &>/dev/null
./easyrsa --batch sign-req  client  client1 &>/dev/null
openvpn --genkey secret "${PKI_DIR}/ta.key"
ok "PKI & certificates generated"

# OpenVPN server config (localhost only — Cloak forwards to it)
cat > /etc/openvpn/server-cloak.conf <<OVPNSRV
local 127.0.0.1
port ${OVPN_PORT}
proto tcp
dev tun1
topology subnet

ca   ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/issued/server.crt
key  ${PKI_DIR}/private/server.key
dh   none
tls-auth ${PKI_DIR}/ta.key 0

server ${OVPN_SUBNET} ${OVPN_MASK}
ifconfig-pool-persist /etc/openvpn/ipp.txt

keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
persist-key
persist-tun
status /var/log/openvpn-cloak-status.log
verb 3
OVPNSRV
ok "OpenVPN server configured"

# Cloak server
mkdir -p /etc/cloak

CK_KEY_RAW=$(ck-server -key 2>&1 || true)
CK_PRIVKEY=$(echo "$CK_KEY_RAW" | grep -i "priv" | sed 's/.*: //' || echo "$CK_KEY_RAW" | head -1)
CK_PUBKEY=$(echo "$CK_KEY_RAW"  | grep -i "pub"  | sed 's/.*: //' || echo "$CK_KEY_RAW" | tail -1)
if [[ -z "$CK_PRIVKEY" || -z "$CK_PUBKEY" ]]; then
    CK_PRIVKEY=$(echo "$CK_KEY_RAW" | head -1 | tr -d '[:space:]')
    CK_PUBKEY=$(echo "$CK_KEY_RAW"  | tail -1 | tr -d '[:space:]')
fi
CK_UID=$(ck-server -u 2>&1 | tr -d '[:space:]')

cat > /etc/cloak/ckserver.json <<CKJSON
{
  "ProxyBook": {
    "openvpn": ["tcp", "127.0.0.1:${OVPN_PORT}"]
  },
  "BindAddr": [":${CLOAK_PORT}"],
  "BypassUID": [],
  "RedirAddr": "${CLOAK_DISGUISE}",
  "PrivateKey": "${CK_PRIVKEY}",
  "AdminUID": "${CK_UID}",
  "DatabasePath": "/etc/cloak/userinfo.db",
  "StreamTimeout": 300
}
CKJSON
ok "Cloak server configured"

# ═════════════════════════════════════════════════════════════════════════════
#  SYSTEMD SERVICES
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/systemd/system/awg-quick@.service <<'UNIT'
[Unit]
Description=AmneziaWG Tunnel %i
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/cloak-server.service <<UNIT
[Unit]
Description=Cloak Server
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/ck-server -c /etc/cloak/ckserver.json
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# ═════════════════════════════════════════════════════════════════════════════
#  START SERVICES
# ═════════════════════════════════════════════════════════════════════════════

echo ""
line
printf "  ${B}Starting services...${N}\n"
line

awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0
systemctl enable awg-quick@awg0 &>/dev/null || true
ok "AmneziaWG  →  awg0  (10.10.10.1)"

systemctl enable --now cloak-server &>/dev/null
ok "Cloak      →  :${CLOAK_PORT}"

systemctl enable --now openvpn@server-cloak &>/dev/null
ok "OpenVPN    →  127.0.0.1:${OVPN_PORT} (via Cloak)"

# ═════════════════════════════════════════════════════════════════════════════
#  GENERATE CLIENT FILES
# ═════════════════════════════════════════════════════════════════════════════

cat > "${OUT_DIR}/client1.ovpn" <<OVPNCLIENT
client
dev tun1
proto tcp
remote 127.0.0.1 1984
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

<ca>
$(cat "${PKI_DIR}/ca.crt")
</ca>
<cert>
$(cat "${PKI_DIR}/issued/client1.crt")
</cert>
<key>
$(cat "${PKI_DIR}/private/client1.key")
</key>
key-direction 1
<tls-auth>
$(cat "${PKI_DIR}/ta.key")
</tls-auth>
OVPNCLIENT

cat > "${OUT_DIR}/client-values.env" <<VALUES
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"
AWG_CLIENT_PRIVKEY="${AWG_CLIENT_PRIVKEY}"
AWG_SERVER_PUBKEY="${AWG_SERVER_PUBKEY}"
AWG_PSK="${AWG_PSK}"
AWG_PORT=${AWG_PORT}
JC=${JC}
JMIN=${JMIN}
JMAX=${JMAX}
S1=${S1}
S2=${S2}
H1=${H1}
H2=${H2}
H3=${H3}
H4=${H4}
CK_PUBKEY="${CK_PUBKEY}"
CK_UID="${CK_UID}"
CLOAK_PORT=${CLOAK_PORT}
CLOAK_DISGUISE="${CLOAK_DISGUISE}"
VALUES

# ═════════════════════════════════════════════════════════════════════════════
#  DONE — SHOW RESULTS
# ═════════════════════════════════════════════════════════════════════════════

clear
printf "${B}${G}"
cat << 'DONE'

  ╔═══════════════════════════════════════════╗
  ║   ✅  SERVER SETUP COMPLETE              ║
  ╚═══════════════════════════════════════════╝

DONE
printf "${N}"

printf "  ${B}Local IPs on this server:${N}\n"
printf "    AmneziaWG : ${G}10.10.10.1${N}\n"
printf "    OpenVPN   : ${G}10.20.20.1${N}\n"
echo ""
line

printf "\n  ${Y}${B}── STEP 1: Copy .ovpn file to client ──${N}\n\n"
printf "  ${C}scp %s/client1.ovpn root@CLIENT_IP:/etc/openvpn/client-cloak.conf${N}\n" "$OUT_DIR"

printf "\n  ${Y}${B}── STEP 2: Run this on the client ──${N}\n\n"
printf "  ${C}curl -sL https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/client-setup.sh | sudo bash${N}\n"

printf "\n  ${Y}${B}── STEP 3: When prompted, paste these values ──${N}\n\n"
line
cat "${OUT_DIR}/client-values.env"
line
echo ""
printf "  ${B}Values also saved to:${N} %s/client-values.env\n\n" "$OUT_DIR"
