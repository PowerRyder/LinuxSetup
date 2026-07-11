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

# WireGuard interface + config path
WG_IFACE="wg0"
CONF="/etc/wireguard/${WG_IFACE}.conf"

# If the server is already configured, steer toward the add-client script and
# never silently change an existing port/subnet.
EXISTING_PORT=""
EXISTING_SUBNET=""
if [[ -f "$CONF" ]]; then
    EXISTING_PORT=$(grep -oP '^\s*ListenPort\s*=\s*\K[0-9]+' "$CONF" | head -1 || true)
    EXISTING_SUBNET=$(grep -oP '^\s*Address\s*=\s*\K[0-9./]+' "$CONF" | head -1 || true)
    echo "⚠️  WireGuard is already configured here (port ${EXISTING_PORT}, subnet ${EXISTING_SUBNET})."
    echo "   ➜ To simply ADD a client, cancel and run:  sudo ./add_wireguard_client.sh"
    echo "     (that keeps your port, keys and existing clients untouched)"
    echo
    read -p "Re-run FULL setup anyway (rewrites ${CONF})? [y/N]: " REDO
    REDO=${REDO:-N}
    if [[ ! "$REDO" =~ ^[Yy]$ ]]; then
        echo "Nothing changed. Exiting."
        exit 0
    fi
    echo "Proceeding with full re-setup (existing port/subnet kept as defaults)..."
    echo
fi

# WireGuard UDP listen port.
# Reuse the existing port if present; otherwise pick a random high port so the
# service is less obvious to port scanners. Press Enter to accept the default.
DEFAULT_PORT=${EXISTING_PORT:-$(shuf -i 20000-60000 -n 1)}
read -p "➡️  WireGuard UDP port [${DEFAULT_PORT}]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

# VPN internal network (server takes .1, clients get .2, .3, ...)
DEFAULT_SUBNET=${EXISTING_SUBNET:-10.0.0.0/24}
read -p "➡️  VPN internal subnet (CIDR) [${DEFAULT_SUBNET}]: " WG_SUBNET
WG_SUBNET=${WG_SUBNET:-$DEFAULT_SUBNET}
# Derive the /24 base (e.g. 10.0.0) and prefix length
WG_BASE=$(echo "$WG_SUBNET" | cut -d'/' -f1 | awk -F'.' '{print $1"."$2"."$3}')
WG_PREFIX=$(echo "$WG_SUBNET" | cut -d'/' -f2)
WG_SERVER_IP="${WG_BASE}.1"

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

# DNS servers pushed to clients (saved as the default for add_wireguard_client.sh)
read -p "➡️  DNS server(s) for clients [1.1.1.1]: " CLIENT_DNS
CLIENT_DNS=${CLIENT_DNS:-1.1.1.1}

echo
echo "📋 Summary:"
echo "   Port            : ${WG_PORT}/udp"
echo "   VPN subnet      : ${WG_BASE}.0/${WG_PREFIX} (server = ${WG_SERVER_IP})"
echo "   WAN interface   : ${NET_IFACE}"
echo "   Endpoint        : ${SERVER_PUBLIC_IP}:${WG_PORT}"
echo "   Outgoing IP     : ${SNAT_IP:-default (masquerade)}"
echo "   Client DNS      : ${CLIENT_DNS}"
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
dnf install -y $DNF_OPTS wireguard-tools firewalld

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

# --- Write the server config (preserving any existing client peers) ----------
# NOTE: this script sets up the SERVER only. It never generates client keys —
# clients create their own keypair locally and are added later, by public key,
# with add_wireguard_client.sh. That way no client private key ever touches the
# server.
echo "📝 Writing server config /etc/wireguard/${WG_IFACE}.conf ..."

# If we're re-running a full setup, keep the [Peer] blocks already present so
# existing clients are not dropped.
EXISTING_PEERS=""
if [[ -f /etc/wireguard/${WG_IFACE}.conf ]]; then
    EXISTING_PEERS=$(awk '/^\[Peer\]/{p=1} p{print}' /etc/wireguard/${WG_IFACE}.conf)
fi

cat > /etc/wireguard/${WG_IFACE}.conf <<EOF
[Interface]
# VPN gateway server
Address = ${WG_SERVER_IP}/${WG_PREFIX}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

PostUp = ${POSTUP}
PostDown = ${POSTDOWN}
EOF

if [[ -n "$EXISTING_PEERS" ]]; then
    echo "   ↺ Preserving existing client peers."
    printf '\n%s\n' "$EXISTING_PEERS" >> /etc/wireguard/${WG_IFACE}.conf
fi

# --- Lock down the server config ---------------------------------------------
chmod 600 /etc/wireguard/${WG_IFACE}.conf

# Save reusable, client-facing parameters so add_wireguard_client.sh can build
# new client configs without asking for them again.
cat > /etc/wireguard/${WG_IFACE}.params <<EOF
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP}
CLIENT_DNS=${CLIENT_DNS}
SNAT_IP=${SNAT_IP}
NET_IFACE=${NET_IFACE}
EOF
chmod 600 /etc/wireguard/${WG_IFACE}.params

# --- Open the firewall port --------------------------------------------------
echo "🧱 Opening firewall UDP port ${WG_PORT}..."
# Add to the RUNNING firewall immediately, then persist it. We deliberately
# avoid `firewall-cmd --reload` here: a reload re-parses EVERY firewalld object
# and aborts if any unrelated one is invalid (e.g. a policy whose name exceeds
# firewalld's 18-char limit). Adding to runtime + permanent gives the same
# result without depending on the rest of the config being valid.
firewall-cmd --add-port=${WG_PORT}/udp || true
firewall-cmd --permanent --add-port=${WG_PORT}/udp || true

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
echo "🔗 Server is ready. A client needs:"
echo "   Endpoint          : ${SERVER_PUBLIC_IP}:${WG_PORT}"
echo "   Server public key : ${SERVER_PUBLIC_KEY}"
echo "   Listening port    : ${WG_PORT}/udp  (opened in firewalld)"
echo
echo "➕ Next step — add a client (no client private key is ever stored here):"
echo "   1. On the client, open the WireGuard app → 'Add empty tunnel'."
echo "      It generates a private key and shows a PUBLIC key."
echo "   2. Copy that public key, then on this server run:"
echo "        sudo ./add_wireguard_client.sh"
echo "      Paste the client's public key when asked; it prints a config to"
echo "      paste back into the client's tunnel."
