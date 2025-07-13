#!/bin/bash
echo "🔧 Setting up Server A (Frontend)..."

read -p "Enter Frontend ID (e.g., 1 for A1, 2 for A2): " FRONTEND_ID
FRONTEND_IP="10.100.${FRONTEND_ID}.2/24"
SERVER_B_IP="10.100.${FRONTEND_ID}.1/32"

LISTEN_PORT=$(shuf -i 30000-60000 -n 1)
echo "🎯 Assigned WireGuard Port: ${LISTEN_PORT}"

# Install dependencies
sudo dnf install epel-release -y
sudo dnf install wireguard-tools firewalld -y
sudo systemctl enable --now firewalld

# Enable WireGuard module
sudo modprobe wireguard
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf > /dev/null

# Generate key pair directly in /etc/wireguard
sudo mkdir -p /etc/wireguard
sudo wg genkey | sudo tee /etc/wireguard/a${FRONTEND_ID}_privatekey | wg pubkey | sudo tee /etc/wireguard/a${FRONTEND_ID}_publickey > /dev/null

# Set secure permissions
sudo chmod 0400 /etc/wireguard/a${FRONTEND_ID}_privatekey
sudo chmod 0644 /etc/wireguard/a${FRONTEND_ID}_publickey

# Read keys
A_PRIVATE_KEY=$(sudo cat /etc/wireguard/a${FRONTEND_ID}_privatekey)
A_PUBLIC_KEY=$(sudo cat /etc/wireguard/a${FRONTEND_ID}_publickey)

echo -e "\n🔑 Public Key for A${FRONTEND_ID} (send to Server B):"
echo "$A_PUBLIC_KEY"

read -p "Paste Server B's Public Key here: " SERVER_B_PUBLIC_KEY

# Create config securely
sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
PrivateKey = ${A_PRIVATE_KEY}
Address = ${FRONTEND_IP}
ListenPort = ${LISTEN_PORT}

[Peer]
PublicKey = ${SERVER_B_PUBLIC_KEY}
AllowedIPs = ${SERVER_B_IP}
EOF

# Set config permissions
sudo chmod 600 /etc/wireguard/wg0.conf

# Open the WireGuard port
sudo firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp
sudo firewall-cmd --reload

# Start tunnel
sudo systemctl enable --now wg-quick@wg0

echo -e "\n✅ Frontend A${FRONTEND_ID} WireGuard tunnel is active."
