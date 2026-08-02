#!/bin/bash

# Cloudflare R2 Backup Push Script
# Uploads local backups to a Cloudflare R2 bucket (S3-compatible) with
# Grandfather-Father-Son rotation:
#   daily/   - uploaded on every run,          kept DAILY_KEEP_DAYS days
#   weekly/  - newest daily copy on WEEKLY_DOW, kept WEEKLY_KEEP_WEEKS weeks
#   monthly/ - newest daily copy on MONTHLY_DOM, kept MONTHLY_KEEP_MONTHS months
# Weekly/monthly copies are server-side (no re-upload).
# Configuration is read from /etc/r2-backup.conf (created by setup_r2_backup.sh)

# Set timezone to India Standard Time
export TZ='Asia/Kolkata'

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG_FILE="/etc/r2-backup.conf"
DATE=$(date +%Y%m%d_%H%M%S)
STAGING_DIR="/var/backups/r2_staging"
FAILURES=0

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - $1"
}

if [ "$EUID" -ne 0 ]; then
    log_message "ERROR: This script must be run as root"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_message "ERROR: Config file $CONFIG_FILE not found. Run setup_r2_backup.sh first."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if ! command -v rclone >/dev/null 2>&1; then
    log_message "ERROR: rclone not found. Run setup_r2_backup.sh first."
    exit 1
fi

REMOTE="r2backup:${R2_BUCKET}/${R2_PREFIX}"

# Decide which rotation tiers apply today
DOW=$(date +%u)          # 1=Mon .. 7=Sun
DOM=$((10#$(date +%d)))  # strip leading zero
RUN_WEEKLY=false
RUN_MONTHLY=false
[ "$DOW" -eq "${WEEKLY_DOW:-7}" ] && RUN_WEEKLY=true
[ "$DOM" -eq "${MONTHLY_DOM:-1}" ] && RUN_MONTHLY=true

# Upload new archive files from a local directory into daily/<name>/
# --max-age keeps rclone from re-uploading old local files that the
# retention pruning has already deleted from the bucket.
push_dir() {
    local src="$1" name="$2" pattern="$3"
    log_message "Uploading new files from $src to daily/$name/"
    if rclone copy "$src" "$REMOTE/daily/$name/" \
        --include "$pattern" --max-age "${DAILY_KEEP_DAYS}d"; then
        log_message "Upload for $name completed"
    else
        log_message "ERROR: Upload for $name failed"
        FAILURES=$((FAILURES + 1))
    fi
}

# Server-side copy of the newest daily object into weekly/ or monthly/
# (dated filenames sort lexically, so the last entry is the newest)
promote_latest() {
    local name="$1" tier="$2" latest
    latest=$(rclone lsf "$REMOTE/daily/$name/" 2>/dev/null | sort | tail -n 1)
    if [ -z "$latest" ]; then
        log_message "WARNING: No daily objects found for $name; skipping $tier copy"
        return
    fi
    log_message "Copying $latest to $tier/$name/ (server-side)"
    if rclone copyto "$REMOTE/daily/$name/$latest" "$REMOTE/$tier/$name/$latest"; then
        log_message "$tier copy for $name completed"
    else
        log_message "ERROR: $tier copy for $name failed"
        FAILURES=$((FAILURES + 1))
    fi
}

log_message "=== Starting R2 backup push ==="

SOURCES=()

# 1. PostgreSQL backups (dated .7z archives created by pg_backup.sh)
if [ -n "$PG_BACKUP_DIR" ]; then
    if [ -d "$PG_BACKUP_DIR" ]; then
        push_dir "$PG_BACKUP_DIR" "postgresql" "backup_*.7z"
        SOURCES+=("postgresql")
    else
        log_message "WARNING: PostgreSQL backup directory $PG_BACKUP_DIR does not exist; skipping"
    fi
fi

# 2. Extra folders: archive fresh, upload, then remove the local archive
if [ -n "$EXTRA_DIRS" ]; then
    mkdir -p "$STAGING_DIR"
    chmod 700 "$STAGING_DIR"
    IFS=',' read -ra DIRS <<< "$EXTRA_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)
        [ -z "$dir" ] && continue
        if [ ! -d "$dir" ]; then
            log_message "WARNING: $dir does not exist; skipping"
            continue
        fi
        name=$(echo "$dir" | sed 's|^/||; s|/|_|g')
        archive="$STAGING_DIR/${name}_${DATE}.tar.gz"
        log_message "Archiving $dir -> $archive"
        if tar -czf "$archive" -C / "${dir#/}"; then
            push_dir "$STAGING_DIR" "$name" "${name}_*.tar.gz"
            SOURCES+=("$name")
        else
            log_message "ERROR: Failed to archive $dir"
            FAILURES=$((FAILURES + 1))
        fi
        rm -f "$archive"
    done
fi

if [ ${#SOURCES[@]} -eq 0 ]; then
    log_message "ERROR: Nothing was uploaded. Check $CONFIG_FILE."
    exit 1
fi

# 3. Weekly/monthly rotation via server-side copies
if $RUN_WEEKLY; then
    log_message "Weekly rotation day: copying newest daily backups to weekly/"
    for name in "${SOURCES[@]}"; do promote_latest "$name" "weekly"; done
fi

if $RUN_MONTHLY; then
    log_message "Monthly rotation day: copying newest daily backups to monthly/"
    for name in "${SOURCES[@]}"; do promote_latest "$name" "monthly"; done
fi

# 4. Retention pruning (ages are based on the backup file's original timestamp)
WEEKLY_KEEP_DAYS=$((WEEKLY_KEEP_WEEKS * 7))
MONTHLY_KEEP_DAYS=$((MONTHLY_KEEP_MONTHS * 31))
log_message "Pruning: daily > ${DAILY_KEEP_DAYS}d, weekly > ${WEEKLY_KEEP_DAYS}d, monthly > ${MONTHLY_KEEP_DAYS}d"
rclone delete "$REMOTE/daily"   --min-age "${DAILY_KEEP_DAYS}d"   2>/dev/null || log_message "WARNING: daily prune reported an error (empty prefix is harmless)"
rclone delete "$REMOTE/weekly"  --min-age "${WEEKLY_KEEP_DAYS}d"  2>/dev/null || log_message "WARNING: weekly prune reported an error (empty prefix is harmless)"
rclone delete "$REMOTE/monthly" --min-age "${MONTHLY_KEEP_DAYS}d" 2>/dev/null || log_message "WARNING: monthly prune reported an error (empty prefix is harmless)"

if [ "$FAILURES" -gt 0 ]; then
    log_message "=== R2 backup push finished with $FAILURES error(s) ==="
    exit 1
fi
log_message "=== R2 backup push completed successfully ==="
