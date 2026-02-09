#!/bin/bash
###############################################################################
#  TUNNEL SERVER SETUP: AmneziaWG + OpenVPN over Cloak
#  Run on your SERVER (Ubuntu 20.04 / 22.04 / 24.04)
#
#  One command:  curl -sL URL | sudo bash
#
#  After setup, it generates a self-contained client installer.
#  Just SCP that file to client and run it — zero manual config needed.
###############################################################################
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'; DIM='\033[2m'
line()  { printf "${C}─────────────────────────────────────────────────${N}\n"; }
ok()    { printf "  ${G}✔${N} %s\n" "$1"; }
info()  { printf "  ${C}ℹ${N} %s\n" "$1"; }
err()   { printf "  ${R}✖${N} %s\n" "$1"; }
step()  { printf "\n${B}▶ [%s] %s${N}\n" "$1" "$2"; }
spin()  {
    local pid=$1 msg=$2
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#chars}; i++ )); do
            printf "\r  ${C}%s${N} %s" "${chars:$i:1}" "$msg"
            sleep 0.1
        done
    done
    wait "$pid" 2>/dev/null || true
    printf "\r\033[2K"
}

[[ $EUID -ne 0 ]] && { err "Run as root: sudo bash $0"; exit 1; }

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

# ── Detect IP ────────────────────────────────────────────────────────────────
detect_ip() {
    for svc in "https://api.ipify.org" "https://checkip.amazonaws.com" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        local ip=$(curl -s --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
}

SERVER_IP=$(detect_ip)
if [[ -n "$SERVER_IP" ]]; then
    printf "  ${G}Detected IP:${N} ${B}%s${N}\n" "$SERVER_IP"
    read -rp "  Use this IP? [Y/n]: " yn < /dev/tty
    [[ "${yn,,}" == "n" ]] && read -rp "  Enter server public IP: " SERVER_IP < /dev/tty
else
    read -rp "  Enter server public IP: " SERVER_IP < /dev/tty
fi
[[ -z "$SERVER_IP" ]] && { err "No IP provided."; exit 1; }

echo ""
line
printf "  ${B}Server IP:${N} %s\n" "$SERVER_IP"
line

# ── Config ───────────────────────────────────────────────────────────────────
AWG_PORT=51820; CLOAK_PORT=443; OVPN_PORT=1194
AWG_SRV="10.10.10.1/24"; AWG_CLI="10.10.10.2/32"
OVPN_NET="10.20.20.0"; OVPN_MASK="255.255.255.0"
CLOAK_DISGUISE="www.bing.com"; CLOAK_VER="2.9.0"
JC=4; JMIN=40; JMAX=70; S1=0; S2=0; H1=1; H2=2; H3=3; H4=4
OUT="/root/tunnel-client-files"; mkdir -p "$OUT"

# ═════════════════════════════════════════════════════════════════════════════
#  INSTALL
# ═════════════════════════════════════════════════════════════════════════════

step "1/6" "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
(apt-get update -qq && apt-get install -y -qq build-essential git pkg-config \
    openvpn easy-rsa wget net-tools iptables curl \
    linux-headers-$(uname -r) 2>/dev/null) &>/dev/null &
spin $! "Installing packages..."
ok "Packages ready"

step "2/6" "Installing Go..."
GO_OK=false
if command -v go &>/dev/null; then
    GM=$(go version 2>/dev/null | grep -oP '1\.\K\d+' || echo "0")
    [[ "$GM" -ge 21 ]] && GO_OK=true && ok "Go $(go version 2>/dev/null | grep -oP 'go[0-9.]+')"
fi
if [[ "$GO_OK" == "false" ]]; then
    if wget -q --timeout=10 "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz" -O /tmp/go.tar.gz 2>/dev/null; then
        rm -rf /usr/local/go; tar -C /usr/local -xzf /tmp/go.tar.gz; rm -f /tmp/go.tar.gz
        ok "Go 1.22.5 installed"
    else
        (apt-get install -y -qq golang-go) &>/dev/null &
        spin $! "Installing Go via apt..."
        command -v go &>/dev/null && ok "Go via apt" || err "Go install failed"
    fi
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
export GOTOOLCHAIN=local GOPROXY=direct GONOSUMCHECK="*" GONOSUMDB="*" GOFLAGS="-mod=mod"

step "3/6" "Installing AmneziaWG..."
# Tools (awg, awg-quick)
if ! command -v awg &>/dev/null; then
    rm -rf /tmp/amneziawg-tools
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
    (make -C /tmp/amneziawg-tools/src -j"$(nproc)" -s && make -C /tmp/amneziawg-tools/src install -s) &>/dev/null &
    spin $! "Building amneziawg-tools..."
    ok "amneziawg-tools"
else
    ok "amneziawg-tools (cached)"
fi

# Kernel module (preferred — no Go needed)
AWG_READY=false
if ! lsmod 2>/dev/null | grep -q amneziawg; then
    rm -rf /tmp/amneziawg-kmod
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git /tmp/amneziawg-kmod
    (cd /tmp/amneziawg-kmod/src && make -j"$(nproc)" && make install) &>/dev/null 2>&1 &
    spin $! "Building kernel module..."
    if modprobe amneziawg 2>/dev/null; then
        AWG_READY=true
        ok "amneziawg kernel module"
    else
        info "Kernel module failed, trying Go userspace..."
    fi
else
    AWG_READY=true
    ok "amneziawg kernel module (loaded)"
fi

# Fallback: Go userspace (only if kernel module failed)
if [[ "$AWG_READY" == "false" ]]; then
    if [[ ! -f /usr/local/bin/amneziawg-go ]] && ! command -v amneziawg-go &>/dev/null; then
        if command -v go &>/dev/null; then
            rm -rf /tmp/amneziawg-go
            git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
            cd /tmp/amneziawg-go
            GLV=$(go version | grep -oP '1\.\d+' | head -1)
            sed -i "s/^go .*/go ${GLV}/" go.mod; sed -i '/^toolchain/d' go.mod
            go env -w GOTOOLCHAIN=local GOPROXY=direct GONOSUMCHECK='*' GONOSUMDB='*' 2>/dev/null || true
            (GOTOOLCHAIN=local GOPROXY=direct make -j"$(nproc)") &>/dev/null 2>&1 &
            spin $! "Building amneziawg-go..."
            [[ -f amneziawg-go ]] && { cp amneziawg-go /usr/local/bin/; ok "amneziawg-go (userspace)"; } || err "amneziawg-go build failed"
        else
            err "No Go compiler available for userspace fallback"
        fi
    else
        ok "amneziawg-go (cached)"
    fi
fi

step "4/6" "Installing Cloak..."
if ! command -v ck-server &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VER}/ck-server-linux-amd64-v${CLOAK_VER}" -O /usr/local/bin/ck-server
    chmod +x /usr/local/bin/ck-server
    ok "Cloak server v${CLOAK_VER}"
else
    ok "Cloak server (cached)"
fi

# IP forwarding
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tunnel.conf
sysctl -p /etc/sysctl.d/99-tunnel.conf &>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
#  GENERATE KEYS
# ═════════════════════════════════════════════════════════════════════════════

step "5/6" "Generating keys & certificates..."
mkdir -p /etc/amnezia/amneziawg /etc/cloak

# AmneziaWG keys
AWG_SK=$(awg genkey); AWG_PK=$(echo "$AWG_SK" | awg pubkey)
AWG_CSK=$(awg genkey); AWG_CPK=$(echo "$AWG_CSK" | awg pubkey)
AWG_PSK=$(awg genpsk)

# Cloak keys
CK_RAW=$(ck-server -key 2>&1 || true)
CK_SK=$(echo "$CK_RAW" | grep -i "priv" | sed 's/.*://; s/[[:space:]]//g')
CK_PK=$(echo "$CK_RAW" | grep -i "pub"  | sed 's/.*://; s/[[:space:]]//g')
[[ -z "$CK_SK" || -z "$CK_PK" ]] && { CK_SK=$(echo "$CK_RAW" | head -1 | tr -d '[:space:]'); CK_PK=$(echo "$CK_RAW" | tail -1 | tr -d '[:space:]'); }
CK_UID=$(ck-server -u 2>&1 | tr -d '[:space:]')

# Easy-RSA PKI
EASYRSA="/etc/openvpn/easy-rsa"; PKI="$EASYRSA/pki"
rm -rf "$EASYRSA"; make-cadir "$EASYRSA"; cd "$EASYRSA"
cat > vars <<'V'
set_var EASYRSA_BATCH "yes"
set_var EASYRSA_REQ_CN "TunnelCA"
set_var EASYRSA_ALGO ec
set_var EASYRSA_CURVE secp384r1
set_var EASYRSA_DIGEST "sha384"
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 3650
V
(./easyrsa init-pki && ./easyrsa --batch build-ca nopass && \
 ./easyrsa --batch gen-req server nopass && ./easyrsa --batch sign-req server server && \
 ./easyrsa --batch gen-req client1 nopass && ./easyrsa --batch sign-req client client1) &>/dev/null &
spin $! "Generating PKI..."
openvpn --genkey secret "$PKI/ta.key"
ok "All keys & certs generated"

# ═════════════════════════════════════════════════════════════════════════════
#  WRITE CONFIGS
# ═════════════════════════════════════════════════════════════════════════════

step "6/6" "Writing configs & starting services..."

# AmneziaWG server
cat > /etc/amnezia/amneziawg/awg0.conf <<AWG
[Interface]
Address = ${AWG_SRV}
ListenPort = ${AWG_PORT}
PrivateKey = ${AWG_SK}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${AWG_CPK}
PresharedKey = ${AWG_PSK}
AllowedIPs = ${AWG_CLI}
AWG
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# OpenVPN server
cat > /etc/openvpn/server-cloak.conf <<OVS
local 127.0.0.1
port ${OVPN_PORT}
proto tcp
dev tun1
topology subnet
ca ${PKI}/ca.crt
cert ${PKI}/issued/server.crt
key ${PKI}/private/server.key
dh none
tls-auth ${PKI}/ta.key 0
server ${OVPN_NET} ${OVPN_MASK}
ifconfig-pool-persist /etc/openvpn/ipp.txt
keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
persist-key
persist-tun
verb 3
OVS

# Cloak server
cat > /etc/cloak/ckserver.json <<CKS
{
  "ProxyBook":{"openvpn":["tcp","127.0.0.1:${OVPN_PORT}"]},
  "BindAddr":[":${CLOAK_PORT}"],
  "BypassUID":[],
  "RedirAddr":"${CLOAK_DISGUISE}",
  "PrivateKey":"${CK_SK}",
  "AdminUID":"${CK_UID}",
  "DatabasePath":"/etc/cloak/userinfo.db",
  "StreamTimeout":300
}
CKS

# Systemd
cat > /etc/systemd/system/awg-quick@.service <<'U'
[Unit]
Description=AmneziaWG %i
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
[Install]
WantedBy=multi-user.target
U

cat > /etc/systemd/system/cloak-server.service <<U
[Unit]
Description=Cloak Server
After=network-online.target
[Service]
ExecStart=/usr/local/bin/ck-server -c /etc/cloak/ckserver.json
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
U

systemctl daemon-reload
if awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0 2>/dev/null; then
    systemctl enable awg-quick@awg0 &>/dev/null || true
    ok "AmneziaWG started (10.10.10.1)"
else
    err "AmneziaWG failed to start — check: journalctl -xeu awg-quick@awg0"
fi
systemctl enable --now cloak-server &>/dev/null && ok "Cloak server started" || err "Cloak server failed"
systemctl enable --now openvpn@server-cloak &>/dev/null && ok "OpenVPN started" || err "OpenVPN failed"

# ═════════════════════════════════════════════════════════════════════════════
#  GENERATE SELF-CONTAINED CLIENT INSTALLER
# ═════════════════════════════════════════════════════════════════════════════

# Read certs for embedding
CA_CRT=$(cat "$PKI/ca.crt")
CLI_CRT=$(cat "$PKI/issued/client1.crt")
CLI_KEY=$(cat "$PKI/private/client1.key")
TA_KEY=$(cat "$PKI/ta.key")

cat > "$OUT/client-install.sh" <<'CLIENTEOF'
#!/bin/bash
set -euo pipefail
R='\033[0;31m';G='\033[0;32m';Y='\033[1;33m';C='\033[0;36m';B='\033[1m';N='\033[0m'
ok(){ printf "  ${G}✔${N} %s\n" "$1"; }
info(){ printf "  ${C}ℹ${N} %s\n" "$1"; }
err(){ printf "  ${R}✖${N} %s\n" "$1"; }
step(){ printf "\n${B}▶ [%s] %s${N}\n" "$1" "$2"; }
spin(){ local pid=$1 msg=$2; local c='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; while kill -0 "$pid" 2>/dev/null; do for((i=0;i<${#c};i++)); do printf "\r  ${C}%s${N} %s" "${c:$i:1}" "$msg"; sleep 0.1; done; done; wait "$pid" 2>/dev/null || true; printf "\r\033[2K"; }
[[ $EUID -ne 0 ]] && { err "Run as root: sudo bash $0"; exit 1; }
clear
printf "${B}${C}\n  ╔═══════════════════════════════════════════╗\n  ║   🛡️  Tunnel Client Setup (auto)          ║\n  ╚═══════════════════════════════════════════╝\n\n${N}"
CLIENTEOF

# Now append the actual values (NOT inside the heredoc so they expand)
cat >> "$OUT/client-install.sh" <<CLIENTVARS
SERVER_IP="${SERVER_IP}"
AWG_CSK="${AWG_CSK}"
AWG_PK="${AWG_PK}"
AWG_PSK="${AWG_PSK}"
AWG_PORT=${AWG_PORT}
JC=${JC};JMIN=${JMIN};JMAX=${JMAX};S1=${S1};S2=${S2};H1=${H1};H2=${H2};H3=${H3};H4=${H4}
CK_PK="${CK_PK}"
CK_UID="${CK_UID}"
CLOAK_PORT=${CLOAK_PORT}
CLOAK_DISGUISE="${CLOAK_DISGUISE}"
CLOAK_VER="${CLOAK_VER}"
CLIENTVARS

cat >> "$OUT/client-install.sh" <<'CLIENTBODY'

info "All config embedded — fully automatic setup"
echo ""

step "1/5" "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
(apt-get update -qq && apt-get install -y -qq build-essential git pkg-config openvpn wget net-tools curl linux-headers-$(uname -r) 2>/dev/null) &>/dev/null &
spin $! "Installing packages..."
ok "Packages ready"

step "2/5" "Installing Go..."
GO_OK=false
if command -v go &>/dev/null; then
    GM=$(go version 2>/dev/null | grep -oP '1\.\K\d+' || echo "0")
    [[ "$GM" -ge 21 ]] && GO_OK=true && ok "Go $(go version 2>/dev/null | grep -oP 'go[0-9.]+')"
fi
if [[ "$GO_OK" == "false" ]]; then
    if wget -q --timeout=10 "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz" -O /tmp/go.tar.gz 2>/dev/null; then
        rm -rf /usr/local/go; tar -C /usr/local -xzf /tmp/go.tar.gz; rm -f /tmp/go.tar.gz
        ok "Go 1.22.5"
    else
        (apt-get install -y -qq golang-go) &>/dev/null &
        spin $! "Installing Go via apt..."
        command -v go &>/dev/null && ok "Go via apt" || err "Go install failed"
    fi
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
export GOTOOLCHAIN=local GOPROXY=direct GONOSUMCHECK="*" GONOSUMDB="*" GOFLAGS="-mod=mod"

step "3/5" "Installing AmneziaWG..."
if ! command -v awg &>/dev/null; then
    rm -rf /tmp/amneziawg-tools
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
    (make -C /tmp/amneziawg-tools/src -j"$(nproc)" -s && make -C /tmp/amneziawg-tools/src install -s) &>/dev/null &
    spin $! "Building amneziawg-tools..."
    ok "amneziawg-tools"
else
    ok "amneziawg-tools (cached)"
fi

# Kernel module (preferred)
AWG_READY=false
if ! lsmod 2>/dev/null | grep -q amneziawg; then
    rm -rf /tmp/amneziawg-kmod
    git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git /tmp/amneziawg-kmod
    (cd /tmp/amneziawg-kmod/src && make -j"$(nproc)" && make install) &>/dev/null 2>&1 &
    spin $! "Building kernel module..."
    if modprobe amneziawg 2>/dev/null; then
        AWG_READY=true
        ok "amneziawg kernel module"
    else
        info "Kernel module failed, trying Go userspace..."
    fi
else
    AWG_READY=true
    ok "amneziawg kernel module (loaded)"
fi

if [[ "$AWG_READY" == "false" ]]; then
    if [[ ! -f /usr/local/bin/amneziawg-go ]] && ! command -v amneziawg-go &>/dev/null; then
        if command -v go &>/dev/null; then
            rm -rf /tmp/amneziawg-go
            git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
            cd /tmp/amneziawg-go
            GLV=$(go version | grep -oP '1\.\d+' | head -1)
            sed -i "s/^go .*/go ${GLV}/" go.mod; sed -i '/^toolchain/d' go.mod
            go env -w GOTOOLCHAIN=local GOPROXY=direct GONOSUMCHECK='*' GONOSUMDB='*' 2>/dev/null || true
            (GOTOOLCHAIN=local GOPROXY=direct make -j"$(nproc)") &>/dev/null 2>&1 &
            spin $! "Building amneziawg-go..."
            [[ -f amneziawg-go ]] && { cp amneziawg-go /usr/local/bin/; ok "amneziawg-go"; } || err "amneziawg-go build failed"
        else
            err "No Go compiler for userspace fallback"
        fi
    else
        ok "amneziawg-go (cached)"
    fi
fi

step "4/5" "Installing Cloak client..."
if ! command -v ck-client &>/dev/null; then
    wget -q "https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VER}/ck-client-linux-amd64-v${CLOAK_VER}" -O /usr/local/bin/ck-client
    chmod +x /usr/local/bin/ck-client
    ok "Cloak client v${CLOAK_VER}"
else
    ok "Cloak client (cached)"
fi

step "5/5" "Configuring tunnels..."

# AmneziaWG
mkdir -p /etc/amnezia/amneziawg
cat > /etc/amnezia/amneziawg/awg0.conf <<AWG
[Interface]
Address = 10.10.10.2/24
PrivateKey = ${AWG_CSK}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${AWG_PK}
PresharedKey = ${AWG_PSK}
Endpoint = ${SERVER_IP}:${AWG_PORT}
AllowedIPs = 10.10.10.1/32
PersistentKeepalive = 25
AWG
chmod 600 /etc/amnezia/amneziawg/awg0.conf
ok "AmneziaWG"

# Cloak client
mkdir -p /etc/cloak
cat > /etc/cloak/ckclient.json <<CKC
{"Transport":"direct","ProxyMethod":"openvpn","EncryptionMethod":"chacha20-poly1305","UID":"${CK_UID}","PublicKey":"${CK_PK}","ServerName":"${CLOAK_DISGUISE}","NumConn":4,"BrowserSig":"chrome","StreamTimeout":300}
CKC
ok "Cloak client"

# OpenVPN client (certs embedded below)
CLIENTBODY

# Embed the .ovpn inline
cat >> "$OUT/client-install.sh" <<OVPNEMBED
mkdir -p /etc/openvpn
cat > /etc/openvpn/client-cloak.conf <<'OVPN'
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
${CA_CRT}
</ca>
<cert>
${CLI_CRT}
</cert>
<key>
${CLI_KEY}
</key>
key-direction 1
<tls-auth>
${TA_KEY}
</tls-auth>
OVPN
ok "OpenVPN"
OVPNEMBED

# Append the service setup and startup
cat >> "$OUT/client-install.sh" <<'CLIENTEND'

# Systemd services
cat > /etc/systemd/system/awg-quick@.service <<'U'
[Unit]
Description=AmneziaWG %i
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
[Install]
WantedBy=multi-user.target
U

cat > /etc/systemd/system/cloak-client.service <<UNIT
[Unit]
Description=Cloak Client
After=network-online.target
[Service]
ExecStart=/usr/local/bin/ck-client -c /etc/cloak/ckclient.json -s ${SERVER_IP} -p ${CLOAK_PORT} -l 127.0.0.1:1984
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/openvpn-cloak.service <<'UNIT'
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
if awg-quick up awg0 2>/dev/null || systemctl start awg-quick@awg0 2>/dev/null; then
    systemctl enable awg-quick@awg0 &>/dev/null || true
    ok "AmneziaWG started (10.10.10.2)"
else
    err "AmneziaWG failed — check: journalctl -xeu awg-quick@awg0"
fi
systemctl enable --now cloak-client &>/dev/null && ok "Cloak client started" || err "Cloak client failed"
systemctl enable --now openvpn-cloak &>/dev/null && ok "OpenVPN started" || err "OpenVPN failed"

echo ""
printf "${B}${G}"
cat << 'DONE'

  ╔═══════════════════════════════════════════╗
  ║   ✅  CLIENT READY                       ║
  ╚═══════════════════════════════════════════╝

DONE
printf "${N}"
printf "  ${B}Your tunnel IPs:${N}\n"
printf "    AmneziaWG : ${G}10.10.10.2${N}  ←→  server 10.10.10.1\n"
printf "    OpenVPN   : ${G}10.20.20.x${N}  ←→  server 10.20.20.1\n\n"
printf "  ${B}Test:${N}  ${C}ping 10.10.10.1${N}  •  ${C}ping 10.20.20.1${N}\n\n"
CLIENTEND

chmod +x "$OUT/client-install.sh"

# ═════════════════════════════════════════════════════════════════════════════
#  DONE — OFFER AUTO-DEPLOY
# ═════════════════════════════════════════════════════════════════════════════

clear
printf "${B}${G}"
cat << 'DONE'

  ╔═══════════════════════════════════════════╗
  ║   ✅  SERVER READY                       ║
  ╚═══════════════════════════════════════════╝

DONE
printf "${N}"
printf "  ${B}Server tunnel IPs:${N}\n"
printf "    AmneziaWG : ${G}10.10.10.1${N}\n"
printf "    OpenVPN   : ${G}10.20.20.1${N}\n\n"
line
printf "\n  ${Y}${B}Deploy to client:${N}\n\n"
printf "  ${DIM}Option 1 — Auto (enter client IP):${N}\n"
printf "  ${DIM}Option 2 — Manual (press Enter to skip):${N}\n\n"

read -rp "  Client IP (or Enter to skip): " CLIENT_IP < /dev/tty

if [[ -n "$CLIENT_IP" ]]; then
    echo ""
    info "Deploying to ${CLIENT_IP}..."
    # Copy installer and run it
    scp -o StrictHostKeyChecking=accept-new "$OUT/client-install.sh" "root@${CLIENT_IP}:/tmp/client-install.sh" < /dev/tty
    ssh -o StrictHostKeyChecking=accept-new "root@${CLIENT_IP}" "bash /tmp/client-install.sh && rm /tmp/client-install.sh" < /dev/tty
else
    echo ""
    printf "  ${B}Manual deploy:${N}\n\n"
    printf "  ${C}scp %s/client-install.sh root@CLIENT_IP:/tmp/${N}\n" "$OUT"
    printf "  ${C}ssh root@CLIENT_IP 'bash /tmp/client-install.sh'${N}\n\n"
fi
