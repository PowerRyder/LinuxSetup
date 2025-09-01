#!/bin/bash
# Script to update PHP-FPM www.conf for Nginx on AlmaLinux 9
# Author: Diana (for Sir)

CONF="/etc/php-fpm.d/www.conf"
BACKUP="/etc/php-fpm.d/www.conf.bak.$(date +%F-%H%M%S)"

echo "🔄 Backing up current config to $BACKUP"
cp "$CONF" "$BACKUP"

echo "⚙️ Updating PHP-FPM pool settings..."

# Replace user/group
sed -i 's/^user = .*/user = nginx/' "$CONF"
sed -i 's/^group = .*/group = nginx/' "$CONF"

# Ensure socket permissions
sed -i 's|^;listen.owner =.*|listen.owner = nginx|' "$CONF"
sed -i 's|^;listen.group =.*|listen.group = nginx|' "$CONF"
sed -i 's|^;listen.mode =.*|listen.mode = 0660|' "$CONF"

# Ensure ACL users are clean (optional)
sed -i 's|^listen.acl_users =.*|;listen.acl_users =|' "$CONF"

# Tune process manager for ~2GB VPS
sed -i 's/^pm = .*/pm = dynamic/' "$CONF"
sed -i 's/^pm.max_children = .*/pm.max_children = 15/' "$CONF"
sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "$CONF"
sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "$CONF"
sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 10/' "$CONF"

# Add or update pm.max_requests
grep -q "^pm.max_requests" "$CONF" \
  && sed -i 's/^pm.max_requests.*/pm.max_requests = 500/' "$CONF" \
  || echo "pm.max_requests = 500" >> "$CONF"

echo "✅ PHP-FPM www.conf updated successfully."

# Restart services
echo "🔄 Restarting PHP-FPM and Nginx..."
systemctl restart php-fpm
systemctl restart nginx

echo "🚀 Update complete. Backup saved at $BACKUP"
