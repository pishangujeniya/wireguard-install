<div align="center">

# `wireguard-install`

**The WireGuard installer that just works.**
One script. Full control. Every subnet your server touches — reachable from anywhere.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](wg-install.sh)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)](#supported-os)
[![WireGuard](https://img.shields.io/badge/WireGuard-%E2%9D%A4-red.svg)](https://wireguard.com)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pishangujeniya/wireguard-install/main/wg-install.sh)
```

</div>

---

## Why this one?

Most WireGuard installers set up a tunnel to the internet.
**This one turns your cloud server into a bastion** — your clients instantly reach every machine in every private network the server is connected to, automatically, without any manual route configuration.

```
  Your Laptop                    Cloud Server (Bastion)
  ─────────────                  ──────────────────────────────────────────
  WireGuard ────── encrypted ──► wg0  (10.112.0.1)
  client                          │
  (10.112.0.2)                    ├── eth0 ──► Internet        (public IP)
                                  ├── eth1 ──► 192.168.100.0/24 (private LAN)
                                  └── eth2 ──► 10.10.0.0/16    (internal cluster)

  ✔  ping 192.168.100.101    works — no routes needed on the LAN machine
  ✔  ssh  10.10.0.50         works
  ✔  curl http://10.10.0.80  works
```

No static routes on private machines. No manual `AllowedIPs` guesswork.
The script detects every connected subnet at install time and bakes them into each client config.

---

## Features

| | |
|---|---|
| **One-command install** | Single `bash` script, no pre-installed dependencies needed |
| **All params configurable** | VPN subnet, port, DNS, MTU, keepalive — every knob exposed with a sensible default |
| **Full subnet discovery** | Auto-detects all server NICs and pushes those routes to every client |
| **Bastion-ready** | All server ports accessible from VPN clients — SSH, databases, dashboards, everything |
| **Stateful firewall** | `conntrack`-based `FORWARD` rules — only established connections flow back, unsolicited inbound is blocked |
| **DoS mitigation** | Rate-limits new WireGuard handshakes (60/min, burst 20) |
| **Live client management** | Add or revoke clients instantly — zero service restarts |
| **QR code output** | Scan directly into the WireGuard mobile app |
| **Preshared keys** | Every peer gets a unique PSK for post-quantum resistance |
| **Multi-distro** | Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, Fedora |

---

## Quick Start

### 1. Run on your server (as root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pishangujeniya/wireguard-install/main/wg-install.sh)
```

Or clone and run locally:

```bash
git clone https://github.com/pishangujeniya/wireguard-install.git
sudo bash wireguard-install/wg-install.sh
```

### 2. Answer the prompts — press Enter to accept any default

```
WireGuard listen port:
Port [51820]:                     ← just press Enter

VPN subnet (must not overlap any existing NIC subnet):
Subnet [10.112.0.0/24]:           ← just press Enter

DNS server(s) pushed to clients (comma-separated IPs):
DNS [1.1.1.1]:                    ← just press Enter

Interface MTU:
MTU [1420]:                       ← just press Enter

PersistentKeepalive for clients (seconds):
Keepalive [25]:                   ← just press Enter

Allow VPN clients to communicate with each other?
Client-to-client [yes]:           ← just press Enter

Name for the first client:
Name [client]: mylaptop
```

### 3. Get your config or QR code

```
Finished! WireGuard is running.

QR code for mylaptop (scan with WireGuard mobile app):
█████████████████████████████████████
████ ▄▄▄▄▄ █▀█ █▄█▀▀▄▀▄█ ▄▄▄▄▄ ████
████ █   █ █▀▀▀█ ▀▀▀▄▄▄█ █   █ ████
████ █▄▄▄█ █▀ █▀▀▀▄▀▀▀ █ █▄▄▄█ ████
...

Config file: /etc/wireguard/clients/mylaptop.conf
```

Import the `.conf` into [WireGuard for Windows / macOS / iOS / Android](https://wireguard.com/install/) and connect.

---

## Managing Clients

Run the script again on the same server — it detects WireGuard is installed and shows the management menu:

```
WireGuard is already installed.

Select an option:
   1) Add a new client
   2) Revoke an existing client
   3) Show client QR code / config path
   4) Update WireGuard
   5) Remove WireGuard
   6) Exit
```

| Option | What it does |
|--------|-------------|
| **Add** | Generates keys + PSK, applies the peer live with `wg set` (no restart), outputs QR code |
| **Revoke** | Removes the peer live, wipes the client `.conf` file from the server |
| **QR** | Re-displays the QR code and config path for any existing client |
| **Update** | Shows the installed WireGuard version, lists installable package versions, and installs your selected version |
| **Remove** | Stops the service, purges packages, removes `/etc/wireguard` entirely |

---

## What the generated client config looks like

```ini
[Interface]
Address = 10.112.0.2/32
PrivateKey = <generated>
DNS = 1.1.1.1
MTU = 1420

[Peer]
# Server
PublicKey = <server-pub>
PresharedKey = <generated-per-client>
Endpoint = your.server.com:51820
AllowedIPs = 10.112.0.0/24, 192.168.100.0/24, 10.10.0.0/16
#                           ↑ auto-detected from server NICs at install time
PersistentKeepalive = 25
```

---

## Security Design

### Can other machines on the same public network spy on or hijack connections?

**No — cryptographically impossible.**
WireGuard decrypts packets before they ever appear on the `wg0` interface. A machine without a registered private key can send UDP to port 51820 all it wants — the server silently drops every packet. Spoofing a VPN client IP from outside the tunnel cannot be done without the client's private key.

### Firewall rules applied

```
# INPUT
-i wg0                                         ACCEPT       ← all server ports open to VPN clients (bastion)
-p udp --dport <port> --ctstate NEW            ACCEPT (rate-limited: 60/min burst 20)  ← DoS protection

# FORWARD (stateful)
-i wg0  --ctstate NEW,RELATED,ESTABLISHED      ACCEPT       ← VPN clients initiate connections outward
-o wg0  --ctstate RELATED,ESTABLISHED          ACCEPT       ← only return traffic comes back in
-i wg0 -o wg0                                  DROP *       ← optional: isolate clients from each other

# NAT
POSTROUTING -s <vpn-subnet>                    MASQUERADE   ← any outgoing NIC; enables all-subnet routing
```

`*` Only added when you answer `no` to the client-to-client prompt.

### File permissions

| Path | Contents | Permissions |
|------|----------|-------------|
| `/etc/wireguard/wg0.conf` | Server private key + peer list | `600` (root only) |
| `/etc/wireguard/params` | Install-time parameters | `600` (root only) |
| `/etc/wireguard/clients/<name>.conf` | Per-client private keys | `600` (root only) |
| `/etc/wireguard/clients.txt` | Client registry (name, pubkey, IP) | default |

---

## How it compares

| Feature | **This script** | wireguard-install (Nyr) | plain `wg-quick` |
|---|:---:|:---:|:---:|
| One-command install | ✅ | ✅ | ❌ |
| Auto-detect all NIC subnets | ✅ | ❌ | ❌ |
| Configurable VPN subnet | ✅ | ❌ | manual |
| Configurable MTU / DNS / keepalive | ✅ | ❌ | manual |
| Stateful iptables (conntrack) | ✅ | ❌ | ❌ |
| Rate-limited WireGuard port | ✅ | ❌ | ❌ |
| Preshared key per peer | ✅ | ✅ | manual |
| Live add/revoke (no restart) | ✅ | ✅ | manual |
| QR code output | ✅ | ✅ | ❌ |
| Bastion / jump-server design | ✅ | ❌ | ❌ |

---

## Supported OS

| Distribution | Minimum version |
|---|---|
| Ubuntu | 22.04 |
| Debian | 11 |
| AlmaLinux / Rocky Linux | 9 |
| CentOS | 9 |
| Fedora | latest |

---

## FAQ

**Q: I added a new NIC to the server after install. Will existing clients reach it?**
Existing client configs won't update automatically. Revoke and re-add the client — the new subnet will be included in the freshly generated `AllowedIPs`.

**Q: Can I use a domain name instead of an IP for the server endpoint?**
Yes. When the installer asks for the public address enter your domain (e.g., `vpn.example.com`). It is written directly into client configs as the `Endpoint`.

**Q: A client can reach the VPN server but not a machine on the private LAN.**
The MASQUERADE rule handles return traffic so the private machine does not need a route back. Verify IP forwarding is active: `sysctl net.ipv4.ip_forward` should return `1`. If not, run `sysctl -w net.ipv4.ip_forward=1`.

**Q: How do I find the optimal MTU to avoid packet fragmentation?**

```bash
# Run from the client side, targeting the VPN server IP
ping -M do -s 1450 10.112.0.1     # if ICMP error → too big, reduce payload
ping -M do -s 1392 10.112.0.1     # if OK → MTU = payload + 28 = 1420
```

Start at 1450 and step down until it succeeds. Add 28 (IP + ICMP headers) to get your MTU value.
Re-install with `MTU = <your value>` or edit `/etc/wireguard/wg0.conf` and restart with `wg-quick down wg0 && wg-quick up wg0`.

**Q: Can I change the VPN subnet after install?**
Run option 4 (Remove WireGuard) and re-run the installer with the new subnet. All client configs will be regenerated.

**Q: Is IPv6 supported?**
Not yet — IPv4 only in this version.

---

## License

MIT — use it, fork it, ship it. Attribution appreciated.

---

<div align="center">

Made with care by [Pishang Ujeniya](https://github.com/pishangujeniya)
Inspired by [Nyr/openvpn-install](https://github.com/Nyr/openvpn-install)

**If this saved you time, drop a ⭐ — it helps others find it.**

</div>
