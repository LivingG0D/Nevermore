#!/bin/bash
###############################################################################
#  TUNNEL CLIENT SETUP: AmneziaWG + OpenVPN over Cloak
#  Run on your CLIENT (Ubuntu 20.04 / 22.04 / 24.04)
#  Usage:  sudo bash client-setup.sh
#
#  BEFORE RUNNING:
#    1. Fill in the values below from server-setup.sh output
#    2. Copy client1.ovpn to this machine at /etc/openvpn/client-cloak.conf
###############################################################################
set -euo pipefail

###############################################################################
#  !! PASTE VALUES FROM SERVER OUTPUT HERE !!
###############################################################################
SERVER_PUBLIC_IP=""

# --- AmneziaWG ---
AWG_CLIENT_PRIVKEY=""
AWG_SERVER_PUBKEY=""
AWG_PSK=""
AWG_PORT=51820
JC=4
JMIN=40
JMAX=70
S1=0
S2=0
H1=1
H2=2
H3=3
H4=4

# --- Cloak ---
CK_PUBKEY=""
CK_UID=""
CLOAK_PORT=443
CLOAK_DISGUISE="www.bing.com"

###############################################################################
#  NETWORK CONFIG  (must match server)
###############################################################################
AWG_CLIENT_ADDR="10.10.10.2/24"
AWG_SERVER_ADDR="10.10.10.1/32"
CK_LOCAL_PORT=1984
CLOAK_VERSION="2.9.0"

###############################################################################
#  VALIDATE
###############################################################################
for var in SERVER_PUBLIC_IP AWG_CLIENT_PRIVKEY AWG_SERVER_PUBKEY AWG_PSK CK_PUBKEY CK_UID; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var is empty. Paste values from server output!"
        exit 1
    fi
done
if [[ $EUID -ne 0 ]]; then
    echo "❌ ERROR: Run as root: sudo bash $0"
    exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Tunnel Client Setup                        ║"
echo "║  Server   : $SERVER_PUBLIC_IP"
echo "╚══════════════════════════════════════════════╝"
echo ""

###############################################################################
#  1. INSTALL BASE PACKAGES
###############################################################################
echo "▶ [1/6] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git pkg-config \
    openvpn wget net-tools curl \
    linux-headers-$(uname -r) 2>/dev/null || true

###############################################################################
#  2. INSTALL GO
###############################################################################
echo "▶ [2/6] Installing Go..."
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
echo "▶ [3/6] Installing AmneziaWG..."
if ! command -v awg &>/dev/null; then
    rm -rf /tmp/amneziawg-tools
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
    make -C /tmp/amneziawg-tools/src -j"$(nproc)"
    make -C /tmp/amneziawg-tools/src install
    echo "  amneziawg-tools installed."
fi
if ! command -v amneziawg-go &>/dev/null && [[ ! -f /usr/local/bin/amneziawg-go ]]; then
    rm -rf /tmp/amneziawg-go
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
    cd /tmp/amneziawg-go
    make -j"$(nproc)"
    cp amneziawg-go /usr/local/bin/
    echo "  amneziawg-go installed."
fi

###############################################################################
#  4. INSTALL CLOAK CLIENT
###############################################################################
echo "▶ [4/6] Installing Cloak client v${CLOAK_VERSION}..."
if ! command -v ck-client &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-client-linux-amd64-v${CLOAK_VERSION}" \
        -O /usr/local/bin/ck-client
    chmod +x /usr/local/bin/ck-client
    echo "  Cloak client installed."
fi

###############################################################################
#  5. CONFIGURE AMNEZIAWG
###############################################################################
echo "▶ [5/6] Configuring AmneziaWG..."
mkdir -p /etc/amnezia/amneziawg

cat > /etc/amnezia/amneziawg/awg0.conf <<CONF
[Interface]
Address    = ${AWG_CLIENT_ADDR}
PrivateKey = ${AWG_CLIENT_PRIVKEY}
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
PublicKey    = ${AWG_SERVER_PUBKEY}
PresharedKey = ${AWG_PSK}
Endpoint     = ${SERVER_PUBLIC_IP}:${AWG_PORT}
AllowedIPs   = ${AWG_SERVER_ADDR}
PersistentKeepalive = 25
CONF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

###############################################################################
#  6. CONFIGURE CLOAK CLIENT + OPENVPN
###############################################################################
echo "▶ [6/6] Configuring Cloak client + OpenVPN..."
mkdir -p /etc/cloak

cat > /etc/cloak/ckclient.json <<CKJSON
{
  "Transport": "direct",
  "ProxyMethod": "openvpn",
  "EncryptionMethod": "chacha20-poly1305",
  "UID": "${CK_UID}",
  "PublicKey": "${CK_PUBKEY}",
  "ServerName": "${CLOAK_DISGUISE}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300
}
CKJSON

# Check that the .ovpn file exists
if [[ ! -f /etc/openvpn/client-cloak.conf ]]; then
    echo ""
    echo "⚠️  /etc/openvpn/client-cloak.conf NOT FOUND!"
    echo "   Copy client1.ovpn from the server to this path."
    echo "   Example:  scp root@${SERVER_PUBLIC_IP}:/root/tunnel-client-files/client1.ovpn /etc/openvpn/client-cloak.conf"
    echo ""
    OVPN_MISSING=true
else
    OVPN_MISSING=false
fi

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

# --- Cloak Client ---
cat > /etc/systemd/system/cloak-client.service <<UNIT
[Unit]
Description=Cloak Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ck-client -c /etc/cloak/ckclient.json -s ${SERVER_PUBLIC_IP} -p ${CLOAK_PORT} -l 127.0.0.1:${CK_LOCAL_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- OpenVPN (client via Cloak) depends on Cloak being up ---
cat > /etc/systemd/system/openvpn-cloak.service <<UNIT
[Unit]
Description=OpenVPN via Cloak
After=cloak-client.service
Requires=cloak-client.service

[Service]
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/client-cloak.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

###############################################################################
#  START SERVICES
###############################################################################
echo ""
echo "▶ Starting services..."

# AmneziaWG
awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0
systemctl enable awg-quick@awg0 2>/dev/null || true
echo "  ✅ AmneziaWG  → awg0  (10.10.10.2)"

# Cloak + OpenVPN
systemctl enable --now cloak-client
echo "  ✅ Cloak client → connecting to ${SERVER_PUBLIC_IP}:${CLOAK_PORT}"

if [[ "$OVPN_MISSING" == "false" ]]; then
    systemctl enable --now openvpn-cloak
    echo "  ✅ OpenVPN    → via Cloak (10.20.20.x)"
else
    echo "  ⏸  OpenVPN    → SKIPPED (copy .ovpn file first, then: systemctl enable --now openvpn-cloak)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅  CLIENT SETUP COMPLETE                                 ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Local IPs on this client:                                 ║"
echo "║    AmneziaWG : 10.10.10.2                                  ║"
echo "║    OpenVPN   : 10.20.20.x  (assigned by server)            ║"
echo "║                                                            ║"
echo "║  Test connectivity:                                        ║"
echo "║    ping 10.10.10.1   # AmneziaWG to server                ║"
echo "║    ping 10.20.20.1   # OpenVPN to server                  ║"
echo "║                                                            ║"
echo "║  Useful commands:                                          ║"
echo "║    awg show                     # AWG status               ║"
echo "║    systemctl status cloak-client                           ║"
echo "║    systemctl status openvpn-cloak                          ║"
echo "║    journalctl -u cloak-client -f                           ║"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
