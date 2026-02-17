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


read -p "Enter the username you want to assign ownership of /var/www: " USER

# Get or create group with GID 1000
if getent group 1000 > /dev/null 2>&1; then
    GROUP_NAME=$(getent group 1000 | cut -d: -f1)
    echo "ℹ️ Using existing group '$GROUP_NAME' (GID 1000)."
else
    GROUP_NAME="sharedgroup"
    sudo groupadd -g 1000 $GROUP_NAME
    echo "✅ Created group '$GROUP_NAME' with GID 1000."
fi
sudo usermod -aG $GROUP_NAME $USER

sudo mkdir -p /var/www
sudo chown -R $USER:$GROUP_NAME /var/www
sudo chmod -R 775 /var/www
sudo chmod -R g+rw /var/www


echo "✅ Setup complete. You can now add your virtual hosts to /etc/nginx/sites-available and symlink them to /etc/nginx/sites-enabled"
