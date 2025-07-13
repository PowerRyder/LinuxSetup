#!/bin/bash
echo "🛡️ Setting up Server B (Backend)..."

read -p "Enter Frontend ID (e.g., 1 for A1, 2 for A2): " FRONTEND_ID
SERVER_B_IP="10.100.${FRONTEND_ID}.1/24"
FRONTEND_IP="10.100.${FRONTEND_ID}.2/32"

read -p "Enter Public IP of Frontend A${FRONTEND_ID}: " FRONTEND_PUBLIC_IP
read -p "Enter WireGuard Port used on A${FRONTEND_ID}: " FRONTEND_PORT

# Install dependencies
sudo dnf install epel-release -y
sudo dnf install wireguard-tools firewalld -y
sudo systemctl enable --now firewalld

# Enable WireGuard module
sudo modprobe wireguard
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf > /dev/null

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
sudo sysctl -p

# Generate key pair directly in /etc/wireguard
sudo mkdir -p /etc/wireguard
sudo wg genkey | sudo tee /etc/wireguard/b${FRONTEND_ID}_privatekey | wg pubkey | sudo tee /etc/wireguard/b${FRONTEND_ID}_publickey > /dev/null

# Set secure permissions
sudo chmod 0400 /etc/wireguard/b${FRONTEND_ID}_privatekey
sudo chmod 0644 /etc/wireguard/b${FRONTEND_ID}_publickey

# Read keys
B_PRIVATE_KEY=$(sudo cat /etc/wireguard/b${FRONTEND_ID}_privatekey)
B_PUBLIC_KEY=$(sudo cat /etc/wireguard/b${FRONTEND_ID}_publickey)

echo -e "\n🔑 Public Key for Server B (send to A${FRONTEND_ID}):"
echo "$B_PUBLIC_KEY"

read -p "Paste Public Key of Frontend A${FRONTEND_ID}: " FRONTEND_PUBLIC_KEY

# Create config securely
sudo tee /etc/wireguard/wg-a${FRONTEND_ID}.conf > /dev/null <<EOF
[Interface]
PrivateKey = ${B_PRIVATE_KEY}
Address = ${SERVER_B_IP}

[Peer]
PublicKey = ${FRONTEND_PUBLIC_KEY}
AllowedIPs = ${FRONTEND_IP}
Endpoint = ${FRONTEND_PUBLIC_IP}:${FRONTEND_PORT}
PersistentKeepalive = 25
EOF

# Set config permissions
sudo chmod 600 /etc/wireguard/wg-a${FRONTEND_ID}.conf

# Start tunnel
sudo systemctl enable --now wg-quick@wg-a${FRONTEND_ID}

echo -e "\n✅ Server B tunnel for Frontend A${FRONTEND_ID} is now active."
