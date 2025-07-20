#!/bin/bash
set -e

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root."
  exit 1
fi

echo "🔄 Updating repos and installing nginx..."
sudo dnf update -y
sudo dnf install -y nginx

echo "✅ Nginx installed successfully."

echo "💾 Backing up nginx.conf..."
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

echo "📂 Creating sites-available and sites-enabled directories..."
sudo mkdir -p /etc/nginx/sites-available
sudo mkdir -p /etc/nginx/sites-enabled

echo "🔗 Adding include line to nginx.conf..."
INCLUDE_LINE="include /etc/nginx/sites-enabled/*;"
sudo sed -i "/http {/a \    $INCLUDE_LINE" /etc/nginx/nginx.conf

echo "🚀 Starting and enabling NGINX..."
sudo systemctl enable nginx
sudo systemctl start nginx


sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload


# Step 11: Prepare default web root
sudo groupadd -g 1000 sharedgroup
sudo usermod -aG sharedgroup $USER

sudo mkdir -p /var/www
sudo chown -R $USER:sharedgroup /var/www
sudo chmod -R 775 /var/www
sudo chmod -R g+rw /var/www

echo "✅ Setup complete. You can now add your virtual hosts to /etc/nginx/sites-available and symlink them to /etc/nginx/sites-enabled"
