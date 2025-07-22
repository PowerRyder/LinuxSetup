#!/bin/bash

# --- Configuration ---
BACKUP_SCRIPT_PATH="/opt/scripts/backup_all_dbs.sh"
SSH_KEY_PATH="/root/.ssh/backup_key" # Using root for cron access
DB_SUPERUSER="postgres"

# --- Script Logic ---
echo "--- 🚀 Starting AlmaLinux DB Server Setup ---"

# 1. Install required packages using dnf
echo "Installing dependencies (postgresql, rsync, cronie)..."
dnf install -y postgresql rsync cronie-anacron > /dev/null
systemctl enable --now crond
echo "✅ Dependencies installed."

# 2. Generate a dedicated SSH key for backups
if [ -f "${SSH_KEY_PATH}" ]; then
    echo "⚠️ SSH key already exists at ${SSH_KEY_PATH}. Skipping generation."
else
    echo "Generating a new SSH key for backups..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N ""
    echo "✅ New SSH key generated."
fi

# 3. Display the public key and wait
echo ""
echo "--- 📋 ACTION REQUIRED 📋 ---"
echo "Copy the entire public key below. You will paste it into the backup server's setup script."
echo "=========================================================================================="
cat "${SSH_KEY_PATH}.pub"
echo "=========================================================================================="
echo "After setting up the backup server with this key, return here and press [Enter] to continue."
read

# 4. Get Backup Server IP
read -p "Enter the IP address of your Backup Server: " BACKUP_SERVER_IP

# 5. Create the main backup script
echo "Creating the backup script at ${BACKUP_SCRIPT_PATH}..."
mkdir -p "$(dirname "$BACKUP_SCRIPT_PATH")"

cat <<EOF > "$BACKUP_SCRIPT_PATH"
#!/bin/bash
# --- Config ---
DB_SUPERUSER="$DB_SUPERUSER"
LOCAL_BACKUP_DIR="/tmp/pg_backups"
REMOTE_USER="backupuser"
REMOTE_SERVER="$BACKUP_SERVER_IP"
REMOTE_DIR="/backups/postgres/"
SSH_KEY="${SSH_KEY_PATH}"

# --- Logic ---
echo "[\$(date)] Starting pg_dumpall for all databases"
mkdir -p \$LOCAL_BACKUP_DIR
FILENAME="all_dbs_\$(date +%Y-%m-%d_%H-%M-%S).sql.gz"
FILEPATH="\$LOCAL_BACKUP_DIR/\$FILENAME"

# Dump and compress
/usr/bin/pg_dumpall -U \$DB_SUPERUSER | /usr/bin/gzip > "\$FILEPATH"

if [ \${PIPESTATUS[0]} -eq 0 ]; then
  echo "[\$(date)] Dump successful: \$FILENAME"
  # Transfer using the dedicated key and remove local file
  /usr/bin/rsync -avz -e "ssh -i \${SSH_KEY}" --remove-source-files "\$FILEPATH" \${REMOTE_USER}@\${REMOTE_SERVER}:\${REMOTE_DIR}
  echo "[\$(date)] Transfer complete."
else
  echo "[\$(date)] Error: pg_dumpall failed."
fi
EOF

chmod +x "$BACKUP_SCRIPT_PATH"
echo "✅ Backup script created."

# 6. Add cron job
echo "Adding cron job..."
(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT_PATH"; echo "0 2 * * * $BACKUP_SCRIPT_PATH >> /var/log/postgres_backup.log 2>&1") | crontab -
echo "✅ Cron job for daily backups is set."

# 7. Final Test
echo "Performing a final connection test to the backup server..."
ssh -i ${SSH_KEY_PATH} backupuser@${BACKUP_SERVER_IP} 'echo "✅ Connection successful!"'

echo "--- 🎉 DB Server Setup Complete! ---"