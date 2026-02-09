#!/bin/bash
###############################################################################
#  TUNNEL CLIENT SETUP: AmneziaWG + OpenVPN over Cloak
#  Run on your CLIENT (Ubuntu 20.04 / 22.04 / 24.04)
#  Usage:  curl -sL URL | sudo bash
#
#  BEFORE RUNNING: Copy client1.ovpn to /etc/openvpn/client-cloak.conf
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
  ║   🛡️  Tunnel Client Setup               ║
  ║   AmneziaWG + OpenVPN over Cloak         ║
  ╚═══════════════════════════════════════════╝

BANNER
printf "${N}"

# ── Interactive prompts ──────────────────────────────────────────────────────
printf "  ${Y}Paste the values from server setup output:${N}\n\n"

read -rp "  Server public IP        : " SERVER_PUBLIC_IP < /dev/tty
echo ""
printf "  ${B}── AmneziaWG keys ──${N}\n"
read -rp "  AWG_CLIENT_PRIVKEY      : " AWG_CLIENT_PRIVKEY < /dev/tty
read -rp "  AWG_SERVER_PUBKEY       : " AWG_SERVER_PUBKEY < /dev/tty
read -rp "  AWG_PSK                 : " AWG_PSK < /dev/tty
echo ""
printf "  ${B}── Cloak keys ──${N}\n"
read -rp "  CK_PUBKEY               : " CK_PUBKEY < /dev/tty
read -rp "  CK_UID                  : " CK_UID < /dev/tty
echo ""

# Validate all fields
for var in SERVER_PUBLIC_IP AWG_CLIENT_PRIVKEY AWG_SERVER_PUBKEY AWG_PSK CK_PUBKEY CK_UID; do
    if [[ -z "${!var}" ]]; then
        err "$var is empty!"; exit 1
    fi
done

# ── Defaults ─────────────────────────────────────────────────────────────────
AWG_PORT=51820
AWG_CLIENT_ADDR="10.10.10.2/24"
AWG_SERVER_ADDR="10.10.10.1/32"
CLOAK_PORT=443
CLOAK_DISGUISE="www.bing.com"
CLOAK_VERSION="2.9.0"
CK_LOCAL_PORT=1984

JC=4; JMIN=40; JMAX=70
S1=0; S2=0
H1=1; H2=2; H3=3; H4=4

echo ""
line
printf "  ${B}Connecting to:${N} %s\n" "$SERVER_PUBLIC_IP"
line

# ═════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════

step "1/5" "Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git pkg-config \
    openvpn wget net-tools curl \
    linux-headers-$(uname -r) 2>/dev/null || true
ok "Base packages ready"

step "2/5" "Installing Go..."
GO_OK=false
if command -v go &>/dev/null; then
    GO_MINOR=$(go version 2>/dev/null | grep -oP '1\.\K\d+' || echo "0")
    if [[ "$GO_MINOR" -ge 21 ]]; then
        GO_OK=true
        ok "Go already installed ($(go version 2>/dev/null | grep -oP 'go[0-9.]+'))"
    fi
fi
if [[ "$GO_OK" == "false" ]]; then
    GO_VER="1.22.5"
    if wget -q --timeout=10 "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O /tmp/go.tar.gz 2>/dev/null; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        ok "Go ${GO_VER} installed (binary)"
    else
        info "Direct download failed, trying apt..."
        apt-get install -y -qq golang-go 2>/dev/null || true
        if command -v go &>/dev/null; then
            ok "Go installed via apt ($(go version 2>/dev/null | grep -oP 'go[0-9.]+'))"
        else
            err "Go installation failed! AmneziaWG build may fail."
        fi
    fi
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

step "3/5" "Installing AmneziaWG..."
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

step "4/5" "Installing Cloak client v${CLOAK_VERSION}..."
if ! command -v ck-client &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-client-linux-amd64-v${CLOAK_VERSION}" \
        -O /usr/local/bin/ck-client
    chmod +x /usr/local/bin/ck-client
    ok "Cloak client installed"
else
    ok "Cloak client already installed"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═════════════════════════════════════════════════════════════════════════════

step "5/5" "Configuring tunnels..."

# AmneziaWG
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
ok "AmneziaWG configured"

# Cloak client
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
ok "Cloak client configured"

# Check for .ovpn file
if [[ ! -f /etc/openvpn/client-cloak.conf ]]; then
    printf "\n  ${Y}⚠  /etc/openvpn/client-cloak.conf not found!${N}\n"
    printf "  ${C}Copy it from server:${N}\n"
    printf "  scp root@%s:/root/tunnel-client-files/client1.ovpn /etc/openvpn/client-cloak.conf\n\n" "$SERVER_PUBLIC_IP"
    OVPN_MISSING=true
else
    ok "OpenVPN config found"
    OVPN_MISSING=false
fi

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

# ═════════════════════════════════════════════════════════════════════════════
#  START SERVICES
# ═════════════════════════════════════════════════════════════════════════════

echo ""
line
printf "  ${B}Starting services...${N}\n"
line

awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0
systemctl enable awg-quick@awg0 &>/dev/null || true
ok "AmneziaWG  →  awg0  (10.10.10.2)"

systemctl enable --now cloak-client &>/dev/null
ok "Cloak      →  connecting to ${SERVER_PUBLIC_IP}:${CLOAK_PORT}"

if [[ "$OVPN_MISSING" == "false" ]]; then
    systemctl enable --now openvpn-cloak &>/dev/null
    ok "OpenVPN    →  via Cloak (10.20.20.x)"
else
    info "OpenVPN    →  SKIPPED (copy .ovpn first, then: systemctl enable --now openvpn-cloak)"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  DONE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
printf "${B}${G}"
cat << 'DONE'

  ╔═══════════════════════════════════════════╗
  ║   ✅  CLIENT SETUP COMPLETE              ║
  ╚═══════════════════════════════════════════╝

DONE
printf "${N}"

printf "  ${B}Local IPs on this client:${N}\n"
printf "    AmneziaWG : ${G}10.10.10.2${N}\n"
printf "    OpenVPN   : ${G}10.20.20.x${N}  (assigned by server)\n"
echo ""
line
printf "\n  ${B}Test connectivity:${N}\n"
printf "    ${C}ping 10.10.10.1${N}   # AmneziaWG → server\n"
printf "    ${C}ping 10.20.20.1${N}   # OpenVPN   → server\n"
printf "\n  ${B}Status:${N}\n"
printf "    ${C}awg show${N}\n"
printf "    ${C}systemctl status cloak-client${N}\n"
printf "    ${C}systemctl status openvpn-cloak${N}\n\n"
