#!/bin/bash

set -e

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root."
  exit 1
fi

read -p "Enter NEW SSH port (e.g., 2222): " NEW_PORT
read -p "Enter the server's IP to bind SSH to: " BIND_IP

# Backup SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo "Backup saved to /etc/ssh/sshd_config.bak"

# Update Port
sed -i "/^\s*#\?\s*Port\s\+/c\Port $NEW_PORT" /etc/ssh/sshd_config

# Disable root login
sed -i "/^\s*#\?\s*PermitRootLogin\s\+/c\PermitRootLogin no" /etc/ssh/sshd_config

# Force IPv4 only
sed -i "/^\s*#\?\s*AddressFamily\s\+/c\AddressFamily inet" /etc/ssh/sshd_config

# Remove all existing ListenAddress lines (commented or not)
sed -i '/^\s*#\?\s*ListenAddress\s\+/d' /etc/ssh/sshd_config

# Add our desired ListenAddress
echo "ListenAddress $BIND_IP" >> /etc/ssh/sshd_config

# Restart sshd
systemctl restart sshd



# Check and handle firewalld
if systemctl is-active --quiet firewalld; then
  echo -e "\n Firewalld is running. Temporarily stopping it to avoid port blocking..."
  systemctl stop firewalld
  echo "Firewalld stopped. You can now test the new SSH connection safely."
else
  echo -e "\n Firewalld is not running. No action needed."
fi


# Install and configure fail2ban
echo -e "\n Installing fail2ban..."
dnf install -y fail2ban

echo -e "\n Configuring fail2ban to monitor port $NEW_PORT..."

# Safely remove any existing [sshd] block from jail.local
if [[ -f /etc/fail2ban/jail.local ]]; then
  awk '
    BEGIN { in_block=0 }
    /^\[sshd\]/ { in_block=1; next }
    /^\[/ && in_block { in_block=0 }
    !in_block { print }
  ' /etc/fail2ban/jail.local > /etc/fail2ban/jail.tmp && mv /etc/fail2ban/jail.tmp /etc/fail2ban/jail.local
fi

# Add updated [sshd] block
cat >> /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = $NEW_PORT
logpath = /var/log/secure
maxretry = 5
bantime = 1h
findtime = 10m

EOF

# Start and enable fail2ban
systemctl enable --now fail2ban
systemctl restart fail2ban

echo -e "\n fail2ban is now protecting SSH on port $NEW_PORT."


# Show success message
echo -e "\n SSH configuration updated and daemon restarted."
echo -e "\n Now test your new SSH connection from a new terminal:"
echo -e "ssh -p $NEW_PORT your_user@$BIND_IP\n"
echo -e "Do NOT close this session until confirmed!"



sudo dnf install -y firewalld

sudo systemctl start firewalld

sudo systemctl enable firewalld

sudo systemctl status firewalld

sudo firewall-cmd --permanent --add-port=$NEW_PORT/tcp

sudo firewall-cmd --permanent --remove-service=ssh

sudo firewall-cmd --permanent --remove-port=22/tcp

sudo firewall-cmd --reload

sudo firewall-cmd --list-all
