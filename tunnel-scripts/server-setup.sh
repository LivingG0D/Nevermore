#!/bin/bash
###############################################################################
#  TUNNEL SERVER SETUP: AmneziaWG + OpenVPN over Cloak
#  Run on your SERVER (Ubuntu 20.04 / 22.04 / 24.04)
#  Usage:  sudo bash server-setup.sh
###############################################################################
set -euo pipefail

###############################################################################
#  !! EDIT THIS SECTION !!
###############################################################################
SERVER_PUBLIC_IP=""           # <-- PUT YOUR SERVER'S PUBLIC IP HERE

###############################################################################
#  NETWORK CONFIG  (defaults are fine)
###############################################################################
AWG_PORT=51820               # AmneziaWG  (UDP)
CLOAK_PORT=443               # Cloak      (TCP, looks like HTTPS)
OVPN_PORT=1194               # OpenVPN    (TCP, localhost only)

AWG_SERVER_ADDR="10.10.10.1/24"
AWG_CLIENT_ADDR="10.10.10.2/32"
OVPN_SUBNET="10.20.20.0"
OVPN_MASK="255.255.255.0"

CLOAK_DISGUISE="www.bing.com"
CLOAK_VERSION="2.9.0"

# AmneziaWG obfuscation knobs
JC=4; JMIN=40; JMAX=70
S1=0; S2=0
H1=1; H2=2; H3=3; H4=4

###############################################################################
#  VALIDATE
###############################################################################
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    echo "❌ ERROR: Set SERVER_PUBLIC_IP at the top of this script!"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "❌ ERROR: Run as root: sudo bash $0"
    exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Tunnel Server Setup                        ║"
echo "║  Server IP : $SERVER_PUBLIC_IP"
echo "╚══════════════════════════════════════════════╝"
echo ""

OUT_DIR="/root/tunnel-client-files"
mkdir -p "$OUT_DIR"

###############################################################################
#  1. INSTALL BASE PACKAGES
###############################################################################
echo "▶ [1/7] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git pkg-config \
    openvpn easy-rsa wget net-tools iptables curl jq \
    linux-headers-$(uname -r) 2>/dev/null || true

###############################################################################
#  2. INSTALL GO (needed for AmneziaWG)
###############################################################################
echo "▶ [2/7] Installing Go..."
if ! command -v go &>/dev/null || [[ $(go version 2>/dev/null | grep -oP '1\.\K\d+' || echo 0) -lt 21 ]]; then
    GO_VER="1.22.5"
    wget -q "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    echo "  Go ${GO_VER} installed."
fi
export PATH="/usr/local/go/bin:$PATH"

###############################################################################
#  3. INSTALL AMNEZIAWG
###############################################################################
echo "▶ [3/7] Installing AmneziaWG..."
if ! command -v awg &>/dev/null; then
    # amneziawg-tools (awg, awg-quick)
    rm -rf /tmp/amneziawg-tools
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
    make -C /tmp/amneziawg-tools/src -j"$(nproc)"
    make -C /tmp/amneziawg-tools/src install
    echo "  amneziawg-tools installed."
fi
if ! command -v amneziawg-go &>/dev/null && [[ ! -f /usr/local/bin/amneziawg-go ]]; then
    # amneziawg-go (userspace daemon)
    rm -rf /tmp/amneziawg-go
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
    cd /tmp/amneziawg-go
    make -j"$(nproc)"
    cp amneziawg-go /usr/local/bin/
    echo "  amneziawg-go installed."
fi

###############################################################################
#  4. INSTALL CLOAK SERVER
###############################################################################
echo "▶ [4/7] Installing Cloak v${CLOAK_VERSION}..."
if ! command -v ck-server &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-server-linux-amd64-v${CLOAK_VERSION}" \
        -O /usr/local/bin/ck-server
    chmod +x /usr/local/bin/ck-server
    echo "  Cloak server installed."
fi

###############################################################################
#  5. ENABLE IP FORWARDING
###############################################################################
echo "▶ [5/7] Enabling IP forwarding..."
cat > /etc/sysctl.d/99-tunnel.conf <<SYSCTL
net.ipv4.ip_forward = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-tunnel.conf > /dev/null

###############################################################################
#  6. CONFIGURE AMNEZIAWG
###############################################################################
echo "▶ [6/7] Configuring AmneziaWG..."
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

###############################################################################
#  7. CONFIGURE OPENVPN  (Easy-RSA PKI + server conf)
###############################################################################
echo "▶ [7/7] Configuring OpenVPN + Cloak..."

EASYRSA_DIR="/etc/openvpn/easy-rsa"
PKI_DIR="${EASYRSA_DIR}/pki"

rm -rf "$EASYRSA_DIR"
make-cadir "$EASYRSA_DIR"
cd "$EASYRSA_DIR"

# vars
cat > vars <<'VARS'
set_var EASYRSA_BATCH      "yes"
set_var EASYRSA_REQ_CN     "TunnelCA"
set_var EASYRSA_KEY_SIZE   2048
set_var EASYRSA_ALGO       ec
set_var EASYRSA_CURVE      secp384r1
set_var EASYRSA_DIGEST     "sha384"
set_var EASYRSA_CA_EXPIRE  3650
set_var EASYRSA_CERT_EXPIRE 3650
VARS

./easyrsa init-pki          2>/dev/null
./easyrsa --batch build-ca nopass  2>/dev/null
./easyrsa --batch gen-req   server  nopass 2>/dev/null
./easyrsa --batch sign-req  server  server 2>/dev/null
./easyrsa --batch gen-req   client1 nopass 2>/dev/null
./easyrsa --batch sign-req  client  client1 2>/dev/null

# TLS Auth key
openvpn --genkey secret "${PKI_DIR}/ta.key"

# Server config  (listens on localhost — Cloak handles external traffic)
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

###############################################################################
#  CLOAK SERVER CONFIG
###############################################################################
mkdir -p /etc/cloak

# Generate Cloak keypair
CK_KEY_RAW=$(ck-server -key 2>&1 || true)
# Parse — output is two lines: first=privkey, second=pubkey  OR labeled
CK_PRIVKEY=$(echo "$CK_KEY_RAW" | grep -i "priv" | sed 's/.*: //' || echo "$CK_KEY_RAW" | head -1)
CK_PUBKEY=$(echo "$CK_KEY_RAW"  | grep -i "pub"  | sed 's/.*: //' || echo "$CK_KEY_RAW" | tail -1)

# If grep failed (no labels), fall back to positional
if [[ -z "$CK_PRIVKEY" || -z "$CK_PUBKEY" ]]; then
    CK_PRIVKEY=$(echo "$CK_KEY_RAW" | head -1 | tr -d '[:space:]')
    CK_PUBKEY=$(echo "$CK_KEY_RAW"  | tail -1 | tr -d '[:space:]')
fi

# Generate UID
CK_UID=$(ck-server -u 2>&1 | tr -d '[:space:]')

# Cloak server JSON
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

###############################################################################
#  SYSTEMD SERVICES
###############################################################################

# --- AmneziaWG ---
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

# --- Cloak Server ---
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

# --- OpenVPN (Cloak) ---
# Relies on the built-in openvpn@.service that ships with the package.

systemctl daemon-reload

###############################################################################
#  START SERVICES
###############################################################################
echo ""
echo "▶ Starting services..."

awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0
systemctl enable awg-quick@awg0 2>/dev/null || true

systemctl enable --now cloak-server
systemctl enable --now openvpn@server-cloak

echo "  ✅ AmneziaWG  → awg0   ($(echo $AWG_SERVER_ADDR | cut -d/ -f1))"
echo "  ✅ Cloak      → :${CLOAK_PORT}"
echo "  ✅ OpenVPN    → 127.0.0.1:${OVPN_PORT} (via Cloak)"

###############################################################################
#  GENERATE CLIENT FILES
###############################################################################

# All-in-one .ovpn with embedded certs
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

# Save values the client script needs
cat > "${OUT_DIR}/client-values.env" <<VALUES
# ============================================================
#  PASTE THESE INTO client-setup.sh ON THE CLIENT MACHINE
# ============================================================

SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"

# --- AmneziaWG ---
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

# --- Cloak ---
CK_PUBKEY="${CK_PUBKEY}"
CK_UID="${CK_UID}"
CLOAK_PORT=${CLOAK_PORT}
CLOAK_DISGUISE="${CLOAK_DISGUISE}"
VALUES

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅  SERVER SETUP COMPLETE                                 ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Local IPs on this server:                                 ║"
echo "║    AmneziaWG : 10.10.10.1                                  ║"
echo "║    OpenVPN   : 10.20.20.1                                  ║"
echo "║                                                            ║"
echo "║  Files for the client saved in:                            ║"
echo "║    ${OUT_DIR}/                                    ║"
echo "║      ├── client-values.env   (paste into client-setup.sh)  ║"
echo "║      └── client1.ovpn        (copy to client)              ║"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "────────────────────────────────────────────────────────────────"
echo "  VALUES TO COPY INTO client-setup.sh:"
echo "────────────────────────────────────────────────────────────────"
cat "${OUT_DIR}/client-values.env"
echo "────────────────────────────────────────────────────────────────"
echo ""
echo "  Also copy ${OUT_DIR}/client1.ovpn to the client at:"
echo "    /etc/openvpn/client-cloak.conf"
echo ""
