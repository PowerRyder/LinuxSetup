#!/bin/bash
#
# install_wireguard_vpn.sh
# -----------------------------------------------------------------------------
# Interactive WireGuard VPN gateway installer for AlmaLinux / Rocky Linux 9+.
#
# Sets up this server as a VPN gateway: clients connect and route ALL of their
# internet traffic out through this server (so their public IP becomes fixed to
# this server's IP). Generates ready-to-use client configs + QR codes.
#
# Run it directly on the server:
#     chmod +x install_wireguard_vpn.sh
#     sudo ./install_wireguard_vpn.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Must run as root (or via sudo) ------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as root:  sudo $0"
    exit 1
fi

echo "🔐 WireGuard VPN Gateway Installer for AlmaLinux / Rocky Linux"
echo "=============================================================="
echo

# --- Gather settings (with sensible defaults) --------------------------------

# WireGuard UDP listen port.
# A random high port is used by default so the service is less obvious to
# port scanners. Press Enter to accept the random one, or type your own.
RANDOM_PORT=$(shuf -i 20000-60000 -n 1)
read -p "➡️  WireGuard UDP port [random: ${RANDOM_PORT}]: " WG_PORT
WG_PORT=${WG_PORT:-$RANDOM_PORT}

# VPN internal network (server takes .1, clients get .2, .3, ...)
read -p "➡️  VPN internal subnet (CIDR) [10.0.0.0/24]: " WG_SUBNET
WG_SUBNET=${WG_SUBNET:-10.0.0.0/24}
# Derive the /24 base (e.g. 10.0.0) and prefix length
WG_BASE=$(echo "$WG_SUBNET" | cut -d'/' -f1 | awk -F'.' '{print $1"."$2"."$3}')
WG_PREFIX=$(echo "$WG_SUBNET" | cut -d'/' -f2)
WG_SERVER_IP="${WG_BASE}.1"

# WireGuard interface name
WG_IFACE="wg0"

# Auto-detect the internet-facing network interface
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
read -p "➡️  Internet-facing network interface [${DEFAULT_IFACE:-eth0}]: " NET_IFACE
NET_IFACE=${NET_IFACE:-${DEFAULT_IFACE:-eth0}}

# Auto-detect the server's public IP (used as the client Endpoint)
DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
read -p "➡️  Server PUBLIC IP / hostname clients connect to [${DETECTED_IP}]: " SERVER_PUBLIC_IP
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-$DETECTED_IP}
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    echo "❌ Could not determine the server's public IP. Please re-run and enter it."
    exit 1
fi

# Outgoing (SNAT) source IP — pins the client's public IP to a specific address.
# Leave blank to use the default masquerade (works for single-IP servers).
read -p "➡️  Fixed outgoing source IP for VPN traffic [blank = auto/masquerade]: " SNAT_IP

# DNS servers pushed to clients
read -p "➡️  DNS server(s) for clients [1.1.1.1]: " CLIENT_DNS
CLIENT_DNS=${CLIENT_DNS:-1.1.1.1}

# How many client configs to generate
read -p "➡️  How many client configs to generate? [1]: " CLIENT_COUNT
CLIENT_COUNT=${CLIENT_COUNT:-1}

echo
echo "📋 Summary:"
echo "   Port            : ${WG_PORT}/udp"
echo "   VPN subnet      : ${WG_BASE}.0/${WG_PREFIX} (server = ${WG_SERVER_IP})"
echo "   WAN interface   : ${NET_IFACE}"
echo "   Endpoint        : ${SERVER_PUBLIC_IP}:${WG_PORT}"
echo "   Outgoing IP     : ${SNAT_IP:-default (masquerade)}"
echo "   Client DNS      : ${CLIENT_DNS}"
echo "   Clients         : ${CLIENT_COUNT}"
echo
read -p "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Install packages --------------------------------------------------------
echo
echo "📦 Installing packages..."
# --setopt=*.skip_if_unavailable=1 keeps an unrelated broken/retired repo
# (e.g. an old pgdg13 PostgreSQL repo returning HTTP 410) from aborting the
# whole transaction — dnf will just skip repos it can't reach.
DNF_OPTS="--setopt=*.skip_if_unavailable=1"
dnf install -y $DNF_OPTS epel-release
dnf install -y $DNF_OPTS wireguard-tools firewalld qrencode

# --- Enable WireGuard kernel module (persist across reboots) ------------------
echo "🧩 Enabling WireGuard kernel module..."
modprobe wireguard
echo wireguard > /etc/modules-load.d/wireguard.conf
lsmod | grep -q wireguard && echo "   ✅ wireguard module loaded"

# --- Enable IP forwarding (persistent) ---------------------------------------
echo "🔀 Enabling IP forwarding..."
cat > /etc/sysctl.d/99-wireguard-forward.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-wireguard-forward.conf > /dev/null

# --- Ensure firewalld is running ---------------------------------------------
systemctl enable --now firewalld

# --- Server keys (reuse existing, otherwise generate) ------------------------
mkdir -p /etc/wireguard/clients
umask 077
if [[ -f /etc/wireguard/server_private.key ]]; then
    echo "🔑 Existing server key found — reusing it."
    # Make sure the public key file is present/consistent with the private key.
    wg pubkey < /etc/wireguard/server_private.key > /etc/wireguard/server_public.pub
else
    echo "🔑 No server key found — generating a new one..."
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.pub
fi
chmod 0400 /etc/wireguard/server_private.key
SERVER_PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.pub)
echo "   🌐 Server PUBLIC key (clients need this):"
echo "      ${SERVER_PUBLIC_KEY}"

# --- Build firewall PostUp / PostDown rules ----------------------------------
# Masquerade + forwarding tie into the interface lifecycle so they are cleanly
# added/removed when the tunnel goes up/down.
POSTUP="firewall-cmd --zone=public --add-masquerade"
POSTUP="${POSTUP}; firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 -i ${WG_IFACE} -o ${NET_IFACE} -j ACCEPT"
POSTUP="${POSTUP}; firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 -i ${NET_IFACE} -o ${WG_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT"

POSTDOWN="firewall-cmd --zone=public --remove-masquerade"
POSTDOWN="${POSTDOWN}; firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 -i ${WG_IFACE} -o ${NET_IFACE} -j ACCEPT"
POSTDOWN="${POSTDOWN}; firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 -i ${NET_IFACE} -o ${WG_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT"

# Pin the outgoing public IP with SNAT if the user asked for a fixed source IP.
if [[ -n "$SNAT_IP" ]]; then
    POSTUP="${POSTUP}; firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s ${WG_BASE}.0/${WG_PREFIX} -o ${NET_IFACE} -j SNAT --to-source ${SNAT_IP}"
    POSTDOWN="${POSTDOWN}; firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s ${WG_BASE}.0/${WG_PREFIX} -o ${NET_IFACE} -j SNAT --to-source ${SNAT_IP}"
fi

# --- Write the server config -------------------------------------------------
echo "📝 Writing server config /etc/wireguard/${WG_IFACE}.conf ..."
cat > /etc/wireguard/${WG_IFACE}.conf <<EOF
[Interface]
# VPN gateway server
Address = ${WG_SERVER_IP}/${WG_PREFIX}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

PostUp = ${POSTUP}
PostDown = ${POSTDOWN}
EOF

# --- Generate clients and append them as peers -------------------------------
echo "👥 Generating ${CLIENT_COUNT} client config(s)..."
for i in $(seq 1 "$CLIENT_COUNT"); do
    default_name="client${i}"
    read -p "   Name for client #${i} [${default_name}]: " CLIENT_NAME </dev/tty
    CLIENT_NAME=${CLIENT_NAME:-$default_name}
    # sanitize name
    CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

    CLIENT_IP="${WG_BASE}.$((i + 1))"

    wg genkey | tee "/etc/wireguard/clients/${CLIENT_NAME}_private.key" \
        | wg pubkey > "/etc/wireguard/clients/${CLIENT_NAME}_public.pub"
    chmod 0400 "/etc/wireguard/clients/${CLIENT_NAME}_private.key"

    CLIENT_PRIVATE_KEY=$(cat "/etc/wireguard/clients/${CLIENT_NAME}_private.key")
    CLIENT_PUBLIC_KEY=$(cat "/etc/wireguard/clients/${CLIENT_NAME}_public.pub")

    # Append the peer to the server config
    cat >> /etc/wireguard/${WG_IFACE}.conf <<EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

    # Build the client-side config (routes ALL traffic through the server)
    CLIENT_CONF="/etc/wireguard/clients/${CLIENT_NAME}.conf"
    cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/${WG_PREFIX}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 0600 "$CLIENT_CONF"
    echo "   ✅ ${CLIENT_NAME} -> ${CLIENT_IP}  (config: ${CLIENT_CONF})"
done

# --- Lock down the server config ---------------------------------------------
chmod 600 /etc/wireguard/${WG_IFACE}.conf

# --- Open the firewall port --------------------------------------------------
echo "🧱 Opening firewall UDP port ${WG_PORT}..."
firewall-cmd --permanent --add-port=${WG_PORT}/udp
firewall-cmd --reload

# --- Start the tunnel --------------------------------------------------------
echo "🚀 Starting WireGuard..."
systemctl daemon-reload
systemctl enable --now wg-quick@${WG_IFACE}
systemctl restart wg-quick@${WG_IFACE}

echo
echo "=============================================================="
echo "✅ WireGuard VPN gateway is up!"
echo
systemctl --no-pager status wg-quick@${WG_IFACE} | head -n 4 || true
echo
wg show || true
echo
echo "🔗 Connection details (what a client needs):"
echo "   Endpoint          : ${SERVER_PUBLIC_IP}:${WG_PORT}"
echo "   Server public key : ${SERVER_PUBLIC_KEY}"
echo "   Listening port    : ${WG_PORT}/udp  (opened in firewalld)"
echo
echo "📱 Client configs are in: /etc/wireguard/clients/*.conf"
echo "   Import the .conf file into the WireGuard app, or scan the QR below."
echo

# --- Print QR codes for each client ------------------------------------------
for conf in /etc/wireguard/clients/*.conf; do
    name=$(basename "$conf" .conf)
    echo "----------------------------------------------------------"
    echo "📲 ${name}"
    echo "----------------------------------------------------------"
    qrencode -t ansiutf8 < "$conf"
    echo
done

echo "Done. To add more clients later, re-run this script or edit /etc/wireguard/${WG_IFACE}.conf"
