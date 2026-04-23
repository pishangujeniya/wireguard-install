#!/bin/bash
#
# WireGuard Road Warrior Installer — Bastion Edition
# Inspired by https://github.com/Nyr/openvpn-install
#
# Features:
#   - All parameters configurable at install with sensible defaults
#   - Clients can reach ALL subnets the server is connected to (auto-detected)
#   - Stateful iptables rules (conntrack) — hardens against unsolicited inbound
#   - Rate-limited WireGuard port to mitigate DoS
#   - Add / revoke clients live (no restart)
#   - QR code output for mobile clients
#
# Supported: Ubuntu 22.04+, Debian 11+, AlmaLinux/Rocky/CentOS 9+, Fedora

if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

read -N 999999 -t 0.001

# ── OS detection ──────────────────────────────────────────────────────────────

if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
else
	echo "Unsupported distribution. Supported: Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, Fedora."
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
CLIENTS_DIR="$WG_DIR/clients"
CLIENTS_FILE="$WG_DIR/clients.txt"
PARAMS_FILE="$WG_DIR/params"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns comma-separated list of all subnets directly reachable via any NIC,
# excluding loopback and the VPN subnet. Lets clients reach every network the
# server is connected to without naming specific interfaces.
get_local_subnets() {
	source "$PARAMS_FILE"
	ip -o -4 route show scope link \
		| awk '{print $1}' \
		| grep -v '^127\.' \
		| grep -v "^${VPN_NET_BASE//./\\.}\." \
		| sort -u \
		| tr '\n' ', ' \
		| sed 's/,$//'
}

build_client_allowed_ips() {
	source "$PARAMS_FILE"
	local subnets
	subnets=$(get_local_subnets)
	if [[ -n "$subnets" ]]; then
		echo "$VPN_SUBNET, $subnets"
	else
		echo "$VPN_SUBNET"
	fi
}

# Finds the next available client IP by scanning existing AllowedIPs in wg0.conf
next_client_ip() {
	source "$PARAMS_FILE"
	local last
	last=$(grep -oE "${VPN_NET_BASE//./\\.}\.[0-9]+/32" "$WG_CONF" 2>/dev/null \
		| grep -oE '[0-9]+/32' | cut -d/ -f1 | sort -n | tail -1)
	[[ -z "$last" ]] && last=1
	echo "$VPN_NET_BASE.$((last + 1))"
}

# Append a [Peer] block to wg0.conf
write_peer_to_conf() {
	local name="$1" pub="$2" psk="$3" ip="$4"
	printf '\n[Peer]\n# %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
		"$name" "$pub" "$psk" "$ip" >> "$WG_CONF"
}

# Remove the [Peer] block containing the given public key from wg0.conf
remove_peer_from_conf() {
	local pub="$1"
	awk -v pub="$pub" '
		/^\[Peer\]/ {
			if (buf != "" && !skip) printf "%s", buf
			buf = $0 "\n"; skip = 0; next
		}
		buf != "" {
			if (index($0, pub)) skip = 1
			buf = buf $0 "\n"; next
		}
		{ print }
		END { if (buf != "" && !skip) printf "%s", buf }
	' "$WG_CONF" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "$WG_CONF"
}

# Write the .conf file for a client, pulling all settings from $PARAMS_FILE
write_client_conf() {
	local name="$1" client_ip="$2" client_priv="$3" psk="$4"
	source "$PARAMS_FILE"
	local allowed_ips
	allowed_ips=$(build_client_allowed_ips)
	mkdir -p "$CLIENTS_DIR"
	cat > "$CLIENTS_DIR/$name.conf" << EOF
[Interface]
Address = $client_ip/32
PrivateKey = $client_priv
DNS = $CLIENT_DNS
MTU = $MTU

[Peer]
# Server
PublicKey = $SERVER_PUB
PresharedKey = $psk
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = $allowed_ips
PersistentKeepalive = $KEEPALIVE
EOF
	chmod 600 "$CLIENTS_DIR/$name.conf"
}

show_qr() {
	local name="$1"
	echo
	if hash qrencode 2>/dev/null; then
		echo "QR code for $name (scan with WireGuard mobile app):"
		qrencode -t ansiutf8 < "$CLIENTS_DIR/$name.conf"
	else
		echo "(Install qrencode to show a QR code)"
	fi
	echo "Config file: $CLIENTS_DIR/$name.conf"
}

sanitize_name() {
	sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$1"
}

# ── Fresh Install ─────────────────────────────────────────────────────────────

if [[ ! -e "$WG_CONF" ]]; then
	clear
	echo 'Welcome to the WireGuard road warrior installer!'
	echo

	# ── Select bind IP ────────────────────────────────────────────────────────
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		bind_ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' \
			| cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo "Which IPv4 address should WireGuard bind to?"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' \
			| cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		bind_ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' \
			| cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "${ip_number}p")
	fi

	# If behind NAT, ask for public endpoint
	if echo "$bind_ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< \
			"$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" \
			|| curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
		endpoint="$public_ip"
	else
		endpoint="$bind_ip"
	fi

	# ── Parameters ────────────────────────────────────────────────────────────
	echo
	echo "WireGuard listen port:"
	read -p "Port [51820]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [51820]: " port
	done
	[[ -z "$port" ]] && port="51820"

	echo
	echo "VPN subnet (must not overlap any existing NIC subnet):"
	read -p "Subnet [10.112.0.0/24]: " vpn_subnet
	until [[ -z "$vpn_subnet" || "$vpn_subnet" =~ ^([0-9]{1,3}\.){3}0/[0-9]{1,2}$ ]]; do
		echo "$vpn_subnet: invalid CIDR — use format like 10.112.0.0/24"
		read -p "Subnet [10.112.0.0/24]: " vpn_subnet
	done
	[[ -z "$vpn_subnet" ]] && vpn_subnet="10.112.0.0/24"

	# Derive server IP (last octet → 1) and prefix base (e.g., 10.112.0)
	vpn_net_base="${vpn_subnet%.*}"
	vpn_server_ip="${vpn_net_base}.1"
	vpn_prefix="${vpn_subnet#*/}"

	echo
	echo "DNS server(s) pushed to clients (comma-separated IPs):"
	read -p "DNS [1.1.1.1]: " client_dns
	[[ -z "$client_dns" ]] && client_dns="1.1.1.1"

	echo
	echo "Interface MTU (1420 works for most; lower if clients report fragmentation):"
	read -p "MTU [1420]: " mtu
	until [[ -z "$mtu" || "$mtu" =~ ^[0-9]+$ && "$mtu" -ge 576 && "$mtu" -le 9000 ]]; do
		echo "$mtu: invalid MTU."
		read -p "MTU [1420]: " mtu
	done
	[[ -z "$mtu" ]] && mtu="1420"

	echo
	echo "PersistentKeepalive for clients (seconds; keeps NAT mappings alive):"
	read -p "Keepalive [25]: " keepalive
	until [[ -z "$keepalive" || "$keepalive" =~ ^[0-9]+$ ]]; do
		echo "$keepalive: invalid."
		read -p "Keepalive [25]: " keepalive
	done
	[[ -z "$keepalive" ]] && keepalive="25"

	echo
	echo "Allow VPN clients to communicate with each other?"
	read -p "Client-to-client [yes]: " c2c
	[[ -z "$c2c" ]] && c2c="yes"
	[[ "$c2c" =~ ^[yY] ]] && client_to_client="yes" || client_to_client="no"

	echo
	echo "Name for the first client:"
	read -p "Name [client]: " unsanitized_client
	first_client=$(sanitize_name "$unsanitized_client")
	[[ -z "$first_client" ]] && first_client="client"

	# ── Install ───────────────────────────────────────────────────────────────
	echo
	echo "WireGuard installation is ready to begin."
	echo "  Endpoint  : $endpoint:$port"
	echo "  VPN subnet: $vpn_subnet (server: $vpn_server_ip)"
	echo "  DNS       : $client_dns"
	echo "  MTU       : $mtu"
	echo "  Keepalive : ${keepalive}s"
	echo "  C2C       : $client_to_client"
	echo "  1st client: $first_client"
	echo
	read -n1 -r -p "Press any key to continue..."
	echo

	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y wireguard qrencode iptables
	elif [[ "$os" = "centos" ]]; then
		dnf install -y epel-release
		dnf install -y wireguard-tools qrencode iptables
	else
		dnf install -y wireguard-tools qrencode iptables
	fi

	# IP forwarding
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-forward.conf
	echo 1 > /proc/sys/net/ipv4/ip_forward

	# Server keys
	server_priv=$(wg genkey)
	server_pub=$(echo "$server_priv" | wg pubkey)

	# Persist all params — used by client-add, helper functions, etc.
	mkdir -p "$WG_DIR"
	cat > "$PARAMS_FILE" << EOF
SERVER_PUB=$server_pub
SERVER_PORT=$port
SERVER_ENDPOINT=$endpoint
VPN_SUBNET=$vpn_subnet
VPN_NET_BASE=$vpn_net_base
VPN_PREFIX=$vpn_prefix
CLIENT_DNS=$client_dns
MTU=$mtu
KEEPALIVE=$keepalive
CLIENT_TO_CLIENT=$client_to_client
EOF
	chmod 600 "$PARAMS_FILE"

	# ── NAT / firewall scripts ────────────────────────────────────────────────
	# Security model:
	#   - MASQUERADE without -o restriction → clients reach all server-connected subnets
	#   - Stateful FORWARD: NEW+ESTABLISHED from wg0; ESTABLISHED only back to wg0
	#     (prevents unsolicited inbound through the FORWARD chain)
	#   - Rate-limited INPUT for WireGuard port (DoS mitigation)
	#   - Full INPUT ACCEPT from wg0 — bastion design: all server services accessible

	# Build optional client-to-client rule lines
	if [[ "$client_to_client" = "no" ]]; then
		c2c_add="\$IPT -I FORWARD 1 -i \$WG_FACE -o \$WG_FACE -j DROP"
		c2c_del="\$IPT -D FORWARD -i \$WG_FACE -o \$WG_FACE -j DROP"
	else
		c2c_add="# client-to-client traffic: allowed"
		c2c_del="# client-to-client traffic: allowed"
	fi

	cat > "$WG_DIR/add-nat.sh" << EOF
#!/bin/bash
## /etc/wireguard/add-nat.sh — generated by wg-install.sh
IPT="/usr/sbin/iptables"
WG_FACE="wg0"
SUB_NET="$vpn_subnet"
WG_PORT="$port"

## NAT: masquerade VPN traffic out any NIC (reaches all server-connected subnets)
\$IPT -t nat -I POSTROUTING 1 -s \$SUB_NET -j MASQUERADE

## INPUT: allow all traffic from VPN interface (bastion — all server ports open to clients)
\$IPT -I INPUT 1 -i \$WG_FACE -j ACCEPT

## INPUT: rate-limit new WireGuard handshakes to mitigate DoS (60/min burst 20)
\$IPT -I INPUT 1 -p udp --dport \$WG_PORT -m conntrack --ctstate NEW \\
     -m limit --limit 60/min --limit-burst 20 -j ACCEPT

## FORWARD: stateful — new+established connections FROM VPN clients
\$IPT -I FORWARD 1 -i \$WG_FACE -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT

## FORWARD: stateful — only established/related return traffic BACK to VPN clients
\$IPT -I FORWARD 1 -o \$WG_FACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

## Client-to-client
$c2c_add
EOF

	cat > "$WG_DIR/del-nat.sh" << EOF
#!/bin/bash
## /etc/wireguard/del-nat.sh — generated by wg-install.sh
IPT="/usr/sbin/iptables"
WG_FACE="wg0"
SUB_NET="$vpn_subnet"
WG_PORT="$port"

\$IPT -t nat -D POSTROUTING -s \$SUB_NET -j MASQUERADE
\$IPT -D INPUT -i \$WG_FACE -j ACCEPT
\$IPT -D INPUT -p udp --dport \$WG_PORT -m conntrack --ctstate NEW \\
     -m limit --limit 60/min --limit-burst 20 -j ACCEPT
\$IPT -D FORWARD -i \$WG_FACE -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
\$IPT -D FORWARD -o \$WG_FACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
$c2c_del
EOF

	chmod +x "$WG_DIR/add-nat.sh" "$WG_DIR/del-nat.sh"

	# ── Server wg0.conf ───────────────────────────────────────────────────────
	cat > "$WG_CONF" << EOF
[Interface]
Address = $vpn_server_ip/$vpn_prefix
MTU = $mtu
PostUp = $WG_DIR/add-nat.sh
PostDown = $WG_DIR/del-nat.sh
ListenPort = $port
PrivateKey = $server_priv
EOF
	chmod 600 "$WG_CONF"

	# ── First client ──────────────────────────────────────────────────────────
	client_priv=$(wg genkey)
	client_pub=$(echo "$client_priv" | wg pubkey)
	client_psk=$(wg genpsk)
	first_client_ip="${vpn_net_base}.2"

	write_peer_to_conf "$first_client" "$client_pub" "$client_psk" "$first_client_ip"
	echo "$first_client $client_pub $first_client_ip" >> "$CLIENTS_FILE"
	write_client_conf "$first_client" "$first_client_ip" "$client_priv" "$client_psk"

	systemctl enable --now wg-quick@wg0

	echo
	echo "Finished! WireGuard is running."
	show_qr "$first_client"

# ── Management Menu ───────────────────────────────────────────────────────────

else
	clear
	echo "WireGuard is already installed."
	echo
	echo "Select an option:"
	echo "   1) Add a new client"
	echo "   2) Revoke an existing client"
	echo "   3) Show client QR code / config path"
	echo "   4) Remove WireGuard"
	echo "   5) Exit"
	read -p "Option: " option
	until [[ "$option" =~ ^[1-5]$ ]]; do
		echo "$option: invalid selection."
		read -p "Option: " option
	done

	case "$option" in

		1)
			echo
			echo "Provide a name for the new client:"
			read -p "Name: " unsanitized_client
			client=$(sanitize_name "$unsanitized_client")
			while [[ -z "$client" || -e "$CLIENTS_DIR/$client.conf" ]]; do
				echo "$client: invalid name or already exists."
				read -p "Name: " unsanitized_client
				client=$(sanitize_name "$unsanitized_client")
			done

			client_ip=$(next_client_ip)
			client_priv=$(wg genkey)
			client_pub=$(echo "$client_priv" | wg pubkey)
			client_psk=$(wg genpsk)

			# Apply live without restart
			if wg show wg0 > /dev/null 2>&1; then
				psk_file=$(mktemp)
				chmod 600 "$psk_file"
				echo "$client_psk" > "$psk_file"
				wg set wg0 peer "$client_pub" preshared-key "$psk_file" allowed-ips "$client_ip/32"
				rm -f "$psk_file"
			fi

			write_peer_to_conf "$client" "$client_pub" "$client_psk" "$client_ip"
			echo "$client $client_pub $client_ip" >> "$CLIENTS_FILE"
			write_client_conf "$client" "$client_ip" "$client_priv" "$client_psk"

			echo
			echo "Client $client added (IP: $client_ip)."
			show_qr "$client"
		;;

		2)
			number_of_clients=$(wc -l < "$CLIENTS_FILE" 2>/dev/null || echo 0)
			if [[ "$number_of_clients" -eq 0 ]]; then
				echo; echo "There are no existing clients!"; exit
			fi
			echo
			echo "Select the client to revoke:"
			awk '{print NR") "$1"  ("$3")"}' "$CLIENTS_FILE"
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Client: " client_number
			done

			client=$(awk "NR==$client_number {print \$1}" "$CLIENTS_FILE")
			client_pub=$(awk "NR==$client_number {print \$2}" "$CLIENTS_FILE")

			echo
			read -p "Confirm revocation of '$client'? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				echo "$revoke: invalid selection."
				read -p "Confirm revocation of '$client'? [y/N]: " revoke
			done

			if [[ "$revoke" =~ ^[yY]$ ]]; then
				wg set wg0 peer "$client_pub" remove 2>/dev/null
				remove_peer_from_conf "$client_pub"
				rm -f "$CLIENTS_DIR/$client.conf"
				sed -i "/^$client /d" "$CLIENTS_FILE"
				echo; echo "$client revoked!"
			else
				echo; echo "Revocation aborted!"
			fi
		;;

		3)
			number_of_clients=$(wc -l < "$CLIENTS_FILE" 2>/dev/null || echo 0)
			if [[ "$number_of_clients" -eq 0 ]]; then
				echo; echo "There are no existing clients!"; exit
			fi
			echo
			echo "Select a client:"
			awk '{print NR") "$1"  ("$3")"}' "$CLIENTS_FILE"
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Client: " client_number
			done
			client=$(awk "NR==$client_number {print \$1}" "$CLIENTS_FILE")
			show_qr "$client"
		;;

		4)
			echo
			read -p "Confirm WireGuard removal? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Confirm WireGuard removal? [y/N]: " remove
			done
			if [[ "$remove" =~ ^[yY]$ ]]; then
				systemctl disable --now wg-quick@wg0
				rm -f /etc/sysctl.d/99-wireguard-forward.conf
				if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
					apt-get remove --purge -y wireguard wireguard-tools
				else
					dnf remove -y wireguard-tools
				fi
				rm -rf "$WG_DIR"
				echo; echo "WireGuard removed!"
			else
				echo; echo "Removal aborted!"
			fi
		;;

		5) exit ;;
	esac
fi
