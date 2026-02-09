# Tunnel Scripts: AmneziaWG + OpenVPN over Cloak

Dual tunnel between two Ubuntu servers — one command each side.

## Architecture

```text
┌────────────────────┐                          ┌────────────────────┐
│    CLIENT           │                          │    SERVER           │
│                     │                          │                     │
│  awg0 (10.10.10.2) │◄──── AmneziaWG (UDP) ───►│  awg0 (10.10.10.1) │
│                     │      port 51820          │                     │
│  tun1 (10.20.20.x) │◄──── OpenVPN ──────────►│  tun1 (10.20.20.1) │
│    ▲                │      via Cloak (TCP 443) │    ▲                │
│    │                │                          │    │                │
│  ck-client ─────────│──── looks like HTTPS ───►│  ck-server          │
│  (localhost:1984)   │                          │  → openvpn:1194     │
└────────────────────┘                          └────────────────────┘
```

## Quick Start

### 1. Run on Server

```bash
curl -sL https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/server-setup.sh | sudo bash
```

That's it. The script will:
- Auto-detect your IP
- Install AmneziaWG + OpenVPN + Cloak
- Generate all keys and certificates
- Start all services
- **Ask for client IP to auto-deploy** (or give you a manual SCP command)

### 2. If Manual Deploy

```bash
scp /root/tunnel-client-files/client-install.sh root@CLIENT_IP:/tmp/
ssh root@CLIENT_IP 'bash /tmp/client-install.sh'
```

### 3. Verify

Run this on **Server** or **Client** to check tunnel health:

```bash
curl -sL https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/test-tunnel.sh | sudo bash
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/uninstall.sh | sudo bash
```

## IP Addresses

| Tunnel    | Server       | Client       |
|-----------|--------------|--------------|
| AmneziaWG | `10.10.10.1` | `10.10.10.2` |
| OpenVPN   | `10.20.20.1` | `10.20.20.x` |

## Useful Commands

```bash
awg show                           # AmneziaWG status
systemctl status cloak-server      # Cloak (server)
systemctl status cloak-client      # Cloak (client)
systemctl status openvpn-cloak     # OpenVPN (client)
systemctl status openvpn@server-cloak  # OpenVPN (server)
```

## Firewall

```bash
ufw allow 51820/udp   # AmneziaWG
ufw allow 443/tcp     # Cloak
```
