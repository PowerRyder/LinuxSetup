#!/bin/bash
#
# add_wireguard_client.sh
# -----------------------------------------------------------------------------
# Add a new client (peer) to an ALREADY-configured WireGuard VPN gateway.
#
# Safe to run any number of times. It does NOT change the server port, keys,
# subnet, firewall, or any existing client — it only appends the new peer and
# hot-loads it with `wg syncconf`, so current connections stay up.
#
# Prerequisite: the server was set up with install_wireguard_vpn.sh.
#
#     chmod +x add_wireguard_client.sh
#     sudo ./add_wireguard_client.sh
# -----------------------------------------------------------------------------

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run as root:  sudo $0"
    exit 1
fi

WG_IFACE="wg0"
CONF="/etc/wireguard/${WG_IFACE}.conf"
CLIENT_DIR="/etc/wireguard/clients"
PARAMS="/etc/wireguard/${WG_IFACE}.params"

if [[ ! -f "$CONF" ]]; then
    echo "❌ No server config found at ${CONF}."
    echo "   Run ./install_wireguard_vpn.sh first to set up the server."
    exit 1
fi
mkdir -p "$CLIENT_DIR"
umask 077

# --- Read server settings straight from the running config -------------------
WG_PORT=$(grep -oP '^\s*ListenPort\s*=\s*\K[0-9]+' "$CONF" | head -1 || true)
SERVER_ADDR=$(grep -oP '^\s*Address\s*=\s*\K[0-9.]+/[0-9]+' "$CONF" | head -1 || true)
WG_BASE=$(echo "$SERVER_ADDR" | cut -d'/' -f1 | awk -F'.' '{print $1"."$2"."$3}')
WG_PREFIX=$(echo "$SERVER_ADDR" | cut -d'/' -f2)

if [[ -z "$WG_PORT" || -z "$WG_BASE" ]]; then
    echo "❌ Could not read ListenPort/Address from ${CONF}. Is it a valid server config?"
    exit 1
fi

# Derive the server public key from its private key
SERVER_PUBLIC_KEY=$(wg pubkey < /etc/wireguard/server_private.key)

# --- Endpoint + DNS (reuse saved params, else detect/prompt) -----------------
SERVER_PUBLIC_IP=""
CLIENT_DNS="1.1.1.1"
if [[ -f "$PARAMS" ]]; then
    # shellcheck disable=SC1090
    source "$PARAMS"
fi
if [[ -z "${SERVER_PUBLIC_IP:-}" ]]; then
    SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
fi
read -p "➡️  Server PUBLIC IP / hostname clients connect to [${SERVER_PUBLIC_IP}]: " _in
SERVER_PUBLIC_IP=${_in:-$SERVER_PUBLIC_IP}
read -p "➡️  DNS server(s) for this client [${CLIENT_DNS}]: " _in
CLIENT_DNS=${_in:-$CLIENT_DNS}

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    echo "❌ Server public IP is required."
    exit 1
fi

# --- Client name -------------------------------------------------------------
read -p "➡️  New client name: " CLIENT_NAME
# keep letters/digits/_/- and allow up to 32 characters
CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-' | cut -c1-32)
if [[ -z "$CLIENT_NAME" ]]; then
    echo "❌ Invalid or empty client name."
    exit 1
fi
if [[ -f "${CLIENT_DIR}/${CLIENT_NAME}.conf" ]]; then
    echo "❌ A client named '${CLIENT_NAME}' already exists (${CLIENT_DIR}/${CLIENT_NAME}.conf)."
    echo "   Choose a different name, or delete the old one first."
    exit 1
fi

# --- Find the next free VPN IP (server is .1) --------------------------------
# Collect the last octet of every AllowedIPs entry that belongs to our subnet.
USED=$(awk -v base="$WG_BASE" '
    $1 == "AllowedIPs" {
        ip = $3
        if (index(ip, base ".") == 1) {
            split(ip, a, ".")
            split(a[4], b, "/")
            print b[1]
        }
    }' "$CONF")

is_used() {
    local n="$1"
    [[ "$n" == "1" ]] && return 0          # .1 is the server
    for u in $USED; do
        [[ "$u" == "$n" ]] && return 0
    done
    return 1
}

NEXT=2
while is_used "$NEXT"; do
    NEXT=$((NEXT + 1))
done
if (( NEXT > 254 )); then
    echo "❌ No free addresses left in ${WG_BASE}.0/${WG_PREFIX}."
    exit 1
fi
CLIENT_IP="${WG_BASE}.${NEXT}"

# --- Generate client keys ----------------------------------------------------
wg genkey | tee "${CLIENT_DIR}/${CLIENT_NAME}_private.key" \
    | wg pubkey > "${CLIENT_DIR}/${CLIENT_NAME}_public.pub"
chmod 0400 "${CLIENT_DIR}/${CLIENT_NAME}_private.key"
CLIENT_PRIVATE_KEY=$(cat "${CLIENT_DIR}/${CLIENT_NAME}_private.key")
CLIENT_PUBLIC_KEY=$(cat "${CLIENT_DIR}/${CLIENT_NAME}_public.pub")

# --- Append the peer to the server config ------------------------------------
cat >> "$CONF" <<EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

# --- Build the client-side config --------------------------------------------
CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"
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

# --- Apply live without disrupting existing peers ----------------------------
if wg show "$WG_IFACE" >/dev/null 2>&1; then
    echo "🔄 Applying new peer to the running tunnel (no restart)..."
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
else
    echo "🚀 Tunnel not running — starting it..."
    systemctl enable --now "wg-quick@${WG_IFACE}"
fi

echo
echo "=============================================================="
echo "✅ Added client '${CLIENT_NAME}'  ->  ${CLIENT_IP}"
echo
echo "🔗 Connection details:"
echo "   Endpoint          : ${SERVER_PUBLIC_IP}:${WG_PORT}"
echo "   Server public key : ${SERVER_PUBLIC_KEY}"
echo "   Config file       : ${CLIENT_CONF}"
echo
echo "📲 Scan this QR with the WireGuard app, or import the .conf above:"
echo "----------------------------------------------------------"
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CLIENT_CONF"
else
    echo "(qrencode not installed — run: sudo dnf install -y qrencode)"
fi
echo "----------------------------------------------------------"
echo
echo "Current peers:"
wg show "$WG_IFACE" || true
