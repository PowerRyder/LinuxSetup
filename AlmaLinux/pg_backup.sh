#!/bin/bash

# PostgreSQL Database Backup Script
# This script logs into the server as postgres user and backs up all databases
# Saves backups in password-protected 7z files with date-wise naming

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Define variables
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
ARCHIVE_FILE="$BACKUP_DIR/backup_${DATE}.7z"
ARCHIVE_PASSWORD="UDp^@Y^rLSzPdCr!j"

# PostgreSQL configuration
PSQL="/usr/pgsql-17/bin/psql"
PG_USER="postgres"
PG_PORT="4268"
PG_DUMP="/usr/pgsql-17/bin/pg_dump"

# Logging
LOGFILE="/var/backups/postgresql/backup_$DATE.log"
TEMP_BACKUP_DIR="$BACKUP_DIR/temp_$DATE"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Function to cleanup on error
cleanup() {
    log_message "Cleaning up temporary files..."
    rm -rf "$TEMP_BACKUP_DIR"
}

# Set up error handling
set -e
trap cleanup EXIT

# Start backup process
log_message "Starting PostgreSQL backup process"

# Ensure backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    log_message "Created backup directory: $BACKUP_DIR"
fi

# Check if required tools are available
if ! command -v 7za >/dev/null 2>&1; then
    log_message "ERROR: 7za command not found. Please install p7zip-full package."
    exit 1
fi

# Switch to the postgres user and perform the backup
sudo -u postgres bash <<EOF
set -e

# Create temporary backup directory
mkdir -p "$TEMP_BACKUP_DIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Created temporary backup directory: $TEMP_BACKUP_DIR" >> "$LOGFILE"

# Test PostgreSQL connection
if ! $PSQL -U $PG_USER -p $PG_PORT -c "SELECT version();" > /dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Cannot connect to PostgreSQL server" >> "$LOGFILE"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Successfully connected to PostgreSQL server" >> "$LOGFILE"

# Get the list of databases (excluding templates)
DBS=\$($PSQL -U $PG_USER -p $PG_PORT -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | grep -v "^\s*$" | tr -d ' ')

if [ -z "\$DBS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: No databases found to backup" >> "$LOGFILE"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Found databases to backup: \$DBS" >> "$LOGFILE"

# Dump each database
BACKUP_COUNT=0
for DB in \$DBS; do
    if [ ! -z "\$DB" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Backing up database: \$DB" >> "$LOGFILE"
        
        if $PG_DUMP -U $PG_USER -p $PG_PORT "\$DB" > "$TEMP_BACKUP_DIR/\${DB}_$DATE.sql" 2>>"$LOGFILE"; then
            BACKUP_SIZE=\$(du -h "$TEMP_BACKUP_DIR/\${DB}_$DATE.sql" | cut -f1)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Successfully backed up \$DB (Size: \$BACKUP_SIZE)" >> "$LOGFILE"
            BACKUP_COUNT=\$((BACKUP_COUNT + 1))
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Failed to backup database \$DB" >> "$LOGFILE"
        fi
    fi
done

echo "$(date '+%Y-%m-%d %H:%M:%S') - Completed backup of \$BACKUP_COUNT databases" >> "$LOGFILE"

# Check if any backups were created
if [ \$BACKUP_COUNT -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: No databases were successfully backed up" >> "$LOGFILE"
    exit 1
fi

EOF

# Check if the postgres user script executed successfully
if [ $? -eq 0 ]; then
    log_message "Database dumps completed successfully"
    
    # Create password-protected 7z archive
    log_message "Creating password-protected 7z archive..."
    
    if 7za a -p"$ARCHIVE_PASSWORD" -mhe=on "$ARCHIVE_FILE" "$TEMP_BACKUP_DIR"/* >> "$LOGFILE" 2>&1; then
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_FILE" | cut -f1)
        log_message "Successfully created archive: $ARCHIVE_FILE (Size: $ARCHIVE_SIZE)"
        
        # Verify archive integrity
        if 7za t -p"$ARCHIVE_PASSWORD" "$ARCHIVE_FILE" > /dev/null 2>&1; then
            log_message "Archive integrity verified successfully"
        else
            log_message "WARNING: Archive integrity check failed"
        fi
    else
        log_message "ERROR: Failed to create 7z archive"
        exit 1
    fi
    
    # Remove the temporary backup directory
    rm -rf "$TEMP_BACKUP_DIR"
    log_message "Removed temporary backup directory"
    
    # Final success message
    log_message "PostgreSQL backup completed successfully!"
    log_message "Archive file: $ARCHIVE_FILE"
    
else
    log_message "ERROR: Database backup process failed"
    exit 1
fi

# Optional: Clean up old backups (uncomment and adjust as needed)
# log_message "Cleaning up backups older than 7 days..."
# find "$BACKUP_DIR" -name "backup_*.7z" -type f -mtime +7 -delete
# find "$BACKUP_DIR" -name "backup_*.log" -type f -mtime +7 -delete

log_message "Backup script execution completed"