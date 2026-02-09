# Tunnel Scripts: AmneziaWG + OpenVPN over Cloak

Two copy-paste scripts to set up a dual tunnel between two Ubuntu servers.

## Architecture

```
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

### Step 1 — Server

```bash
curl -sLO https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/server-setup.sh && nano server-setup.sh && sudo bash server-setup.sh
```

> Set `SERVER_PUBLIC_IP` when the editor opens, save, and the script runs automatically.
> It will print values at the end — **copy them**.

### Step 2 — Client

```bash
# Copy the .ovpn file from server:
scp root@YOUR_SERVER:/root/tunnel-client-files/client1.ovpn /etc/openvpn/client-cloak.conf

# Download and run client script:
curl -sLO https://raw.githubusercontent.com/LivingG0D/Nevermore/main/tunnel-scripts/client-setup.sh && nano client-setup.sh && sudo bash client-setup.sh
```

> Paste the values from Step 1 when the editor opens.

### Step 3 — Test

```bash
ping 10.10.10.1   # AmneziaWG tunnel
ping 10.20.20.1   # OpenVPN tunnel
```

## IP Addresses

| Tunnel    | Server       | Client       |
|-----------|-------------|-------------|
| AmneziaWG | `10.10.10.1` | `10.10.10.2` |
| OpenVPN   | `10.20.20.1` | `10.20.20.x` |

## Ports

| Service   | Port | Protocol | Notes                    |
|-----------|------|----------|--------------------------|
| AmneziaWG | 51820 | UDP    | Direct                   |
| Cloak     | 443   | TCP    | Disguised as HTTPS       |
| OpenVPN   | 1194  | TCP    | Localhost only (via Cloak)|

## Useful Commands

```bash
# AmneziaWG
awg show                              # status
awg-quick down awg0                   # stop
awg-quick up awg0                     # start

# Cloak
systemctl status cloak-server         # (server)
systemctl status cloak-client         # (client)
journalctl -u cloak-server -f         # logs

# OpenVPN
systemctl status openvpn@server-cloak # (server)
systemctl status openvpn-cloak        # (client)
journalctl -u openvpn-cloak -f        # logs
```

## Firewall

If you have `ufw` or `iptables` rules, open these on the **server**:

```bash
ufw allow 51820/udp   # AmneziaWG
ufw allow 443/tcp     # Cloak
```
