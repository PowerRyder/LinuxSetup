#!/bin/bash
#
# add_wireguard_client.sh
# -----------------------------------------------------------------------------
# Add a client (peer) to an already-configured WireGuard VPN gateway — WITHOUT
# ever handling the client's private key.
#
# The client generates its own keypair locally (e.g. WireGuard app -> "Add empty
# tunnel"), and you paste only its PUBLIC key here. This script:
#   * appends the peer (public key + assigned VPN IP) to the server config,
#   * hot-loads it with `wg syncconf` (existing connections stay up),
#   * prints a ready-to-paste client config (with a placeholder for the private
#     key, which never leaves the client).
#
# Prerequisite: server was set up with install_wireguard_vpn.sh.
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

# --- Client name (label only — used for the peer comment + a local record) ---
read -p "➡️  Client name (label): " CLIENT_NAME
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

# --- Client PUBLIC key (generated on the client, pasted here) ----------------
echo
echo "On the client device: open the WireGuard app, choose 'Add empty tunnel'"
echo "(it creates the private key locally and shows a Public key), then copy that"
echo "public key and paste it below."
echo
read -p "➡️  Client PUBLIC key: " CLIENT_PUBLIC_KEY
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PUBLIC_KEY" | tr -d '[:space:]')

# Validate it looks like a WireGuard key (32 bytes base64 -> 44 chars ending '=')
if [[ ! "$CLIENT_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "❌ That doesn't look like a valid WireGuard public key (expected 44 base64 chars ending in '=')."
    exit 1
fi
# Reject duplicates
if grep -qF "$CLIENT_PUBLIC_KEY" "$CONF"; then
    echo "❌ This public key is already configured as a peer. Nothing to do."
    exit 1
fi

# --- Find the next free VPN IP (server is .1) --------------------------------
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

# --- Append the peer to the server config ------------------------------------
cat >> "$CONF" <<EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

# --- Save a local record of this peer (no secrets in it) ---------------------
# This documents which VPN IP / public key belongs to which client. It is a
# TEMPLATE: the PrivateKey line stays a placeholder that only the client fills.
CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"
umask 077
cat > "$CLIENT_CONF" <<EOF
# Client: ${CLIENT_NAME}  (VPN IP ${CLIENT_IP})
# PublicKey (on server) = ${CLIENT_PUBLIC_KEY}
[Interface]
PrivateKey = <YOUR_CLIENT_PRIVATE_KEY_STAYS_ON_THE_CLIENT>
Address = ${CLIENT_IP}/${WG_PREFIX}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# --- Apply live without disrupting existing peers ----------------------------
if wg show "$WG_IFACE" >/dev/null 2>&1; then
    echo "🔄 Applying new peer to the running tunnel (no restart)..."
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
else
    echo "🚀 Tunnel not running — starting it..."
    systemctl enable --now "wg-quick@${WG_IFACE}"
fi

# --- Show the client what to paste -------------------------------------------
echo
echo "=============================================================="
echo "✅ Added client '${CLIENT_NAME}'  ->  ${CLIENT_IP}"
echo
echo "📋 Paste the following into the client's WireGuard tunnel."
echo "   The [Interface] already has the private key it generated — you only"
echo "   need to set Address/DNS and add the [Peer] block. Full config shown:"
echo "--------------------------8<--------------------------------"
cat <<EOF
[Interface]
# (keep the PrivateKey the client already generated)
Address = ${CLIENT_IP}/${WG_PREFIX}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF
echo "-------------------------->8--------------------------------"
echo
echo "(A copy of this — with a private-key placeholder — is saved for your"
echo " records at ${CLIENT_CONF}; it contains no secrets.)"
echo
echo "Current peers:"
wg show "$WG_IFACE" || true
