#!/bin/bash
set -e

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root."
  exit 1
fi

# Step 1: Install required packages
sudo yum install -y yum-utils

# Step 2: Add Nginx repository
cat <<EOF | sudo tee /etc/yum.repos.d/nginx.repo
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF

# Step 3: Enable mainline version
sudo yum-config-manager --enable nginx-mainline

# Step 4: Update and install nginx
sudo yum update -y
sudo yum install -y nginx

# Step 5: Start and enable nginx
sudo systemctl start nginx
sudo systemctl enable nginx

# Step 6: Backup original nginx config
NGINX_CONF="/etc/nginx/nginx.conf"
sudo cp "$NGINX_CONF" "$NGINX_CONF.bak"

# Step 7: Ensure required directories exist
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# Step 8: Insert include line if not already present
INCLUDE_LINE="include /etc/nginx/sites-enabled/*;"
grep -qF "$INCLUDE_LINE" "$NGINX_CONF" || sudo sed -i "/http {/a \    $INCLUDE_LINE" "$NGINX_CONF"

# Step 9: Add HTTP/3 and gzip settings if not already present
declare -a SETTINGS=(
    "http2 on;"
    "http3 on;"
    "quic_retry on;"
    "ssl_session_cache shared:SSL:50m;"
    "ssl_session_timeout 1d;"
    "add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
    "gzip on;"
    "gzip_vary on;"
    "gzip_min_length 1000;"
    "gzip_comp_level 5;"
    "gzip_proxied any;"
    "gzip_types text/plain text/css application/javascript application/json image/svg+xml;"
)

for SETTING in "${SETTINGS[@]}"; do
    grep -qF "$SETTING" "$NGINX_CONF" || sudo sed -i "/http {/a \    $SETTING" "$NGINX_CONF"
done

# Step 10: Firewall rules for HTTP/3
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=443/udp
sudo firewall-cmd --reload

# Step 11: Prepare default web root
read -p "Enter the username you want to assign ownership of /var/www: " USER

sudo groupadd -g 1000 sharedgroup
sudo usermod -aG sharedgroup $USER

sudo mkdir -p /var/www
sudo chown -R $USER:sharedgroup /var/www
sudo chmod -R 775 /var/www
sudo chmod -R g+rw /var/www

echo "✅ Nginx with HTTP/3 and QUIC installed and configured successfully."
