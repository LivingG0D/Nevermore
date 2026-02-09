#!/bin/bash
###############################################################################
#  TUNNEL UNINSTALL: Removes AmneziaWG + OpenVPN + Cloak
#  Works on both SERVER and CLIENT (auto-detects)
#  Usage:  sudo bash uninstall.sh
###############################################################################
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ Run as root: sudo bash $0"
    exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Tunnel Uninstaller                         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Stop & disable services ──────────────────────────────────────────────────
echo "▶ Stopping services..."
awg-quick down awg0 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true

systemctl stop cloak-server 2>/dev/null || true
systemctl disable cloak-server 2>/dev/null || true

systemctl stop cloak-client 2>/dev/null || true
systemctl disable cloak-client 2>/dev/null || true

systemctl stop openvpn@server-cloak 2>/dev/null || true
systemctl disable openvpn@server-cloak 2>/dev/null || true

systemctl stop openvpn-cloak 2>/dev/null || true
systemctl disable openvpn-cloak 2>/dev/null || true

# ── Remove systemd units ─────────────────────────────────────────────────────
echo "▶ Removing systemd services..."
rm -f /etc/systemd/system/awg-quick@.service
rm -f /etc/systemd/system/cloak-server.service
rm -f /etc/systemd/system/cloak-client.service
rm -f /etc/systemd/system/openvpn-cloak.service
systemctl daemon-reload

# ── Remove configs ────────────────────────────────────────────────────────────
echo "▶ Removing configs..."
rm -rf /etc/amnezia
rm -rf /etc/cloak
rm -f /etc/openvpn/server-cloak.conf
rm -f /etc/openvpn/client-cloak.conf
rm -rf /etc/openvpn/easy-rsa
rm -f /etc/openvpn/ipp.txt
rm -f /etc/sysctl.d/99-tunnel.conf
rm -rf /root/tunnel-client-files

# ── Remove binaries ──────────────────────────────────────────────────────────
echo "▶ Removing binaries..."
rm -f /usr/local/bin/ck-server
rm -f /usr/local/bin/ck-client
rm -f /usr/local/bin/amneziawg-go
rm -f /usr/bin/awg /usr/bin/awg-quick 2>/dev/null || true
rm -f /usr/local/bin/awg /usr/local/bin/awg-quick 2>/dev/null || true

# ── Remove build leftovers ───────────────────────────────────────────────────
echo "▶ Cleaning build files..."
rm -rf /tmp/amneziawg-tools
rm -rf /tmp/amneziawg-go

# ── Reload sysctl ────────────────────────────────────────────────────────────
sysctl --system > /dev/null 2>&1 || true

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅  UNINSTALL COMPLETE                     ║"
echo "║                                             ║"
echo "║  Removed:                                   ║"
echo "║    • AmneziaWG (config + binaries)          ║"
echo "║    • Cloak (config + binaries)              ║"
echo "║    • OpenVPN tunnel configs                 ║"
echo "║    • Systemd services                       ║"
echo "║                                             ║"
echo "║  NOT removed (shared packages):             ║"
echo "║    • openvpn, easy-rsa, golang, build tools ║"
echo "║    Run: apt remove openvpn easy-rsa         ║"
echo "╚══════════════════════════════════════════════╝"
