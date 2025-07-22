#!/bin/bash

echo "--- 🚀 Starting AlmaLinux Backup Server Setup ---"

# 1. Install dependencies
echo "Installing rsync and cronie..."
dnf install -y rsync cronie-anacron > /dev/null
systemctl enable --now crond
echo "✅ Dependencies installed."

# 2. Create a non-login backup user
if id "backupuser" &>/dev/null; then
    echo "⚠️ User 'backupuser' already exists. Skipping creation."
else
    # Creates user, group, and home directory
    useradd --system --shell /bin/bash --create-home backupuser
    echo "✅ System user 'backupuser' created."
fi

# 3. Create backup directory and set permissions
BACKUP_DIR="/backups/postgres"
mkdir -p "$BACKUP_DIR"
chown -R backupuser:backupuser "$BACKUP_DIR"
echo "✅ Backup directory created at $BACKUP_DIR."

# 4. Set up SSH for the backup user
SSH_DIR=$(eval echo ~backupuser)/.ssh
AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS_FILE"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS_FILE"
chown -R backupuser:backupuser "$SSH_DIR"
echo "✅ SSH directory configured."

# 5. Get the public key from the user
echo ""
echo "--- 📋 ACTION REQUIRED 📋 ---"
read -p "Paste the public SSH key from the DB server and press [Enter]: " SSH_PUBLIC_KEY

# 6. Add the key to authorized_keys, restricting it to rsync
if grep -qF "$SSH_PUBLIC_KEY" "$AUTH_KEYS_FILE"; then
    echo "⚠️ Key already exists in authorized_keys."
else
    # Find and copy rrsync script for extra security
    RRSYNC_SCRIPT=$(find /usr/share/doc/rsync* -name rrsync)
    RRSYNC_PATH="/usr/local/bin/rrsync"
    
    # Add key with rrsync restriction if available
    if [ -n "$RRSYNC_SCRIPT" ]; then
        cp "$RRSYNC_SCRIPT" "$RRSYNC_PATH"
        chmod +x "$RRSYNC_PATH"
        echo "command=\"$RRSYNC_PATH $BACKUP_DIR\" $SSH_PUBLIC_KEY" >> "$AUTH_KEYS_FILE"
        echo "✅ Public key added with rsync restriction."
    else
        echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS_FILE"
        echo "✅ Public key added. (rrsync script not found, key not restricted)."
    fi
fi

# 7. Create a retention policy script to delete old backups
RETENTION_SCRIPT_PATH="/opt/scripts/cleanup_backups.sh"
mkdir -p "$(dirname "$RETENTION_SCRIPT_PATH")"

cat <<EOF > "$RETENTION_SCRIPT_PATH"
#!/bin/bash
# Deletes backups in the specified directory older than 30 days.
find $BACKUP_DIR -type f -mtime +30 -name '*.sql.gz' -delete
echo "[\$(date)] Old backups cleanup complete."
EOF

chmod +x "$RETENTION_SCRIPT_PATH"
echo "✅ Retention policy script created at $RETENTION_SCRIPT_PATH."

# 8. Add a cron job for the cleanup script
(crontab -l 2>/dev/null | grep -v "$RETENTION_SCRIPT_PATH"; echo "0 4 * * * $RETENTION_SCRIPT_PATH >> /var/log/cleanup_backups.log 2>&1") | crontab -
echo "✅ Cron job for daily cleanup is set."

echo "--- 🎉 Backup Server Setup Complete! ---"