#!/bin/bash
###############################################################################
#  TUNNEL HEALTH CHECK
#  Run on Server OR Client to verify connectivity
#  Usage: curl -sL URL | sudo bash
###############################################################################
set -euo pipefail
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

clear
printf "${B}${C}\n  ╔═══════════════════════════════════════════╗\n  ║   🩺  Tunnel Health Check                 ║\n  ╚═══════════════════════════════════════════╝\n\n${N}"

# 1. Detect Role
if ip a | grep -q "10.10.10.1"; then
    ROLE="SERVER"
    PEER_AWG="10.10.10.2"
    PEER_OVPN="10.20.20.x (Client)"
    TargetIP="10.20.20.2" # Assuming first client gets .2 usually
elif ip a | grep -q "10.10.10.2"; then
    ROLE="CLIENT"
    PEER_AWG="10.10.10.1"
    PEER_OVPN="10.20.20.1"
    TargetIP="10.20.20.1"
else
    printf "  ${R}✖  Neither Server (10.10.10.1) nor Client (10.10.10.2) detected!${N}\n"
    exit 1
fi

printf "  ${B}Role:${N} ${Y}$ROLE${N}\n\n"

# 2. AmneziaWG Check
printf "  ${B}1. AmneziaWG (UDP 51820)${N}\n"
if ip link show awg0 &>/dev/null; then
    printf "     Interface awg0: ${G}UP${N}\n"
    if ping -c 1 -W 2 "$PEER_AWG" &>/dev/null; then
        printf "     Ping $PEER_AWG: ${G}SUCCESS${N} (Latency: $(ping -c 1 "$PEER_AWG" | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}') ms)\n"
    else
        printf "     Ping $PEER_AWG: ${R}FAILED${N} (Check Firewall on Server: udp/51820)\n"
    fi
else
    printf "     Interface awg0: ${R}MISSING${N}\n"
fi
echo ""

# 3. OpenVPN over Cloak Check
printf "  ${B}2. OpenVPN over Cloak (TCP 443)${N}\n"
if systemctl is-active --quiet cloak-server || systemctl is-active --quiet cloak-client; then
    printf "     Cloak Service:  ${G}ACTIVE${N}\n"
else
    printf "     Cloak Service:  ${R}INACTIVE${N}\n"
fi

if ip link show tun1 &>/dev/null; then
    printf "     Interface tun1: ${G}UP${N}\n"
    # Only client can ping server reliably usually, server can ping client if it knows the IP
    if [[ "$ROLE" == "CLIENT" ]]; then
        if ping -c 1 -W 2 "$TargetIP" &>/dev/null; then
            printf "     Ping $TargetIP: ${G}SUCCESS${N} (Latency: $(ping -c 1 "$TargetIP" | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}') ms)\n"
        else
            printf "     Ping $TargetIP: ${R}FAILED${N} (Check Firewall on Server: tcp/443)\n"
        fi
    else
        printf "     (Server mode: Waiting for incoming OpenVPN connections...)\n"
    fi
else
    printf "     Interface tun1: ${R}MISSING${N} (OpenVPN not connected)\n"
fi
echo ""

# 4. Service Status
printf "  ${B}3. Systemd Services${N}\n"
for svc in awg-quick@awg0 cloak-server cloak-client openvpn-cloak openvpn@server-cloak; do
    if systemctl list-units --full -all | grep -q "$svc.service"; then
        if systemctl is-active --quiet "$svc"; then
            printf "     %-20s ${G}ACTIVE${N}\n" "$svc"
        else
            printf "     %-20s ${R}FAILED${N}\n" "$svc"
        fi
    fi
done
echo ""
