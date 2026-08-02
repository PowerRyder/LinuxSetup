#!/bin/bash

# Cloudflare R2 Backup Sync Setup Script
# Installs rclone, configures a Cloudflare R2 remote, deploys r2_backup_push.sh
# and schedules a daily cron job with Grandfather-Father-Son retention
# (daily / weekly / monthly copies in the bucket).

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

RCLONE_CONF="/root/.config/rclone/rclone.conf"
CONFIG_FILE="/etc/r2-backup.conf"
PUSH_SCRIPT_DEST="/usr/local/bin/r2_backup_push.sh"
LOG_FILE="/var/log/r2-backup.log"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to collect R2 credentials and retention policy
collect_r2_config() {
    print_status "Cloudflare R2 details (create an S3 API token in the Cloudflare dashboard under R2 -> Manage API Tokens):"

    read -p "Cloudflare Account ID: " CF_ACCOUNT_ID
    if [ -z "$CF_ACCOUNT_ID" ]; then
        print_error "Account ID cannot be empty. Aborting."
        exit 1
    fi

    read -p "R2 Access Key ID: " R2_ACCESS_KEY
    read -s -p "R2 Secret Access Key: " R2_SECRET_KEY
    echo
    if [ -z "$R2_ACCESS_KEY" ] || [ -z "$R2_SECRET_KEY" ]; then
        print_error "Access key and secret cannot be empty. Aborting."
        exit 1
    fi

    read -p "R2 bucket name: " R2_BUCKET
    if ! [[ "$R2_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
        print_error "Invalid bucket name. Aborting."
        exit 1
    fi

    DEFAULT_PREFIX=$(hostname -s)
    read -p "Folder prefix inside the bucket [${DEFAULT_PREFIX}]: " R2_PREFIX
    R2_PREFIX=${R2_PREFIX:-$DEFAULT_PREFIX}

    echo
    print_status "Retention policy (how long each backup tier is kept):"

    read -p "Keep DAILY backups for how many days? [10]: " DAILY_KEEP_DAYS
    DAILY_KEEP_DAYS=${DAILY_KEEP_DAYS:-10}
    read -p "Keep WEEKLY backups for how many weeks? [5]: " WEEKLY_KEEP_WEEKS
    WEEKLY_KEEP_WEEKS=${WEEKLY_KEEP_WEEKS:-5}
    read -p "Keep MONTHLY backups for how many months? [9]: " MONTHLY_KEEP_MONTHS
    MONTHLY_KEEP_MONTHS=${MONTHLY_KEEP_MONTHS:-9}
    for v in "$DAILY_KEEP_DAYS" "$WEEKLY_KEEP_WEEKS" "$MONTHLY_KEEP_MONTHS"; do
        if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ]; then
            print_error "Retention values must be positive numbers. Aborting."
            exit 1
        fi
    done

    echo
    print_status "What to back up:"

    read -p "PostgreSQL backup directory to push [/var/backups/postgresql]: " PG_BACKUP_DIR
    PG_BACKUP_DIR=${PG_BACKUP_DIR:-/var/backups/postgresql}
    if [ ! -d "$PG_BACKUP_DIR" ]; then
        print_warning "$PG_BACKUP_DIR does not exist yet (ok if you set up pg backups later)"
    fi

    read -p "Extra folders to back up (comma-separated absolute paths, blank for none): " EXTRA_DIRS
    if [ -n "$EXTRA_DIRS" ]; then
        IFS=',' read -ra DIRS <<< "$EXTRA_DIRS"
        for dir in "${DIRS[@]}"; do
            dir=$(echo "$dir" | xargs)
            [ -z "$dir" ] && continue
            if [[ "$dir" != /* ]]; then
                print_error "Extra folder paths must be absolute: $dir. Aborting."
                exit 1
            fi
            if [ ! -d "$dir" ]; then
                print_warning "$dir does not exist yet; it will be skipped until it does"
            fi
        done
    fi
}

# Function to install rclone
install_rclone() {
    print_status "Installing rclone..."

    if command -v rclone >/dev/null 2>&1; then
        print_success "rclone is already installed ($(rclone version | head -n 1))"
        return
    fi

    dnf install -y epel-release >/dev/null 2>&1 || true
    if dnf install -y rclone; then
        print_success "rclone installed via dnf"
    else
        print_status "dnf install failed, using the official rclone install script..."
        curl -fsSL https://rclone.org/install.sh | bash
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        print_error "rclone installation failed"
        exit 1
    fi
    print_success "rclone is available ($(rclone version | head -n 1))"
}

# Function to configure the R2 remote in rclone
configure_rclone_remote() {
    print_status "Configuring rclone remote 'r2backup'..."

    mkdir -p "$(dirname "$RCLONE_CONF")"
    touch "$RCLONE_CONF"
    chmod 600 "$RCLONE_CONF"

    # Replace any previous r2backup section without touching other remotes
    if grep -q '^\[r2backup\]' "$RCLONE_CONF"; then
        print_status "Removing existing 'r2backup' remote..."
        rclone config delete r2backup
    fi

    cat >> "$RCLONE_CONF" <<EOF

[r2backup]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    print_success "rclone remote 'r2backup' configured (credentials in $RCLONE_CONF)"
}

# Function to verify connectivity and bucket access
test_r2_connection() {
    print_status "Testing connection to bucket '${R2_BUCKET}'..."

    if rclone lsd "r2backup:${R2_BUCKET}" >/dev/null 2>&1; then
        print_success "Bucket '${R2_BUCKET}' is reachable"
        return
    fi

    print_status "Bucket not reachable, trying to create it..."
    if rclone mkdir "r2backup:${R2_BUCKET}" >/dev/null 2>&1; then
        print_success "Bucket '${R2_BUCKET}' created"
    else
        print_error "Cannot access or create bucket '${R2_BUCKET}'."
        print_error "Check the Account ID / keys, and that the API token has read & write access."
        print_error "If the token is scoped, create the bucket manually in the Cloudflare dashboard first."
        exit 1
    fi
}

# Function to write the push script configuration
write_config() {
    print_status "Writing configuration to $CONFIG_FILE..."

    cat > "$CONFIG_FILE" <<EOF
# Cloudflare R2 backup push configuration (used by r2_backup_push.sh)
# Generated by setup_r2_backup.sh on $(date '+%Y-%m-%d %H:%M:%S')
R2_BUCKET="${R2_BUCKET}"
R2_PREFIX="${R2_PREFIX}"
DAILY_KEEP_DAYS=${DAILY_KEEP_DAYS}
WEEKLY_KEEP_WEEKS=${WEEKLY_KEEP_WEEKS}
MONTHLY_KEEP_MONTHS=${MONTHLY_KEEP_MONTHS}
WEEKLY_DOW=7    # day of the week for the weekly copy (1=Mon .. 7=Sun)
MONTHLY_DOM=1   # day of the month for the monthly copy
PG_BACKUP_DIR="${PG_BACKUP_DIR}"
EXTRA_DIRS="${EXTRA_DIRS}"
EOF
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration written"
}

# Function to deploy the push script
deploy_push_script() {
    print_status "Deploying r2_backup_push.sh to $PUSH_SCRIPT_DEST..."

    if [ ! -f "./r2_backup_push.sh" ]; then
        print_error "r2_backup_push.sh not found in current directory"
        print_error "Please ensure r2_backup_push.sh is in the same directory as this setup script"
        exit 1
    fi

    cp "./r2_backup_push.sh" "$PUSH_SCRIPT_DEST"
    chmod 700 "$PUSH_SCRIPT_DEST"
    chown root:root "$PUSH_SCRIPT_DEST"

    if bash -n "$PUSH_SCRIPT_DEST"; then
        print_success "Push script deployed and syntax validated"
    else
        print_error "Push script syntax validation failed"
        exit 1
    fi
}

# Function to setup cron job (3:30 AM IST, after the 2:00 AM pg backup)
setup_cronjob() {
    print_status "Setting up daily cron job at 3:30 AM..."

    local TMP_CRON="/tmp/current_crontab_$$"
    > "$TMP_CRON"
    if crontab -l >/dev/null 2>&1; then
        crontab -l > "$TMP_CRON" 2>/dev/null
    fi

    # Remove old duplicate entries
    sed -i '/r2_backup_push\.sh/d' "$TMP_CRON" 2>/dev/null || true

    echo "30 3 * * * $PUSH_SCRIPT_DEST >> $LOG_FILE 2>&1" >> "$TMP_CRON"

    if crontab "$TMP_CRON"; then
        print_success "Cron job installed"
    else
        print_error "Failed to install cron job"
        rm -f "$TMP_CRON"
        exit 1
    fi
    rm -f "$TMP_CRON"

    if systemctl is-active --quiet crond; then
        print_success "Cron service is running"
    else
        print_status "Starting cron service..."
        systemctl enable --now crond
        print_success "Cron service started and enabled"
    fi
}

# Function to display summary
display_summary() {
    echo
    print_success "=== Cloudflare R2 Backup Sync Setup Complete ==="
    echo
    echo "Configuration Summary:"
    echo "  • Bucket:          ${R2_BUCKET} (prefix: ${R2_PREFIX}/)"
    echo "  • Daily backups:   kept ${DAILY_KEEP_DAYS} days       -> ${R2_PREFIX}/daily/"
    echo "  • Weekly backups:  kept ${WEEKLY_KEEP_WEEKS} weeks (copied Sundays) -> ${R2_PREFIX}/weekly/"
    echo "  • Monthly backups: kept ${MONTHLY_KEEP_MONTHS} months (copied on the 1st) -> ${R2_PREFIX}/monthly/"
    echo "  • PostgreSQL dir:  ${PG_BACKUP_DIR}"
    echo "  • Extra folders:   ${EXTRA_DIRS:-none}"
    echo "  • Schedule:        Daily at 3:30 AM (after the 2:00 AM pg backup)"
    echo "  • Config file:     ${CONFIG_FILE}"
    echo "  • Log file:        ${LOG_FILE}"
    echo
    echo "Next Steps:"
    echo "  1. Test the push manually: sudo $PUSH_SCRIPT_DEST"
    echo "  2. Check uploaded files:   rclone lsf r2backup:${R2_BUCKET}/${R2_PREFIX}/daily/ -R"
    echo "  3. Monitor logs:           tail -f $LOG_FILE"
    echo
    print_warning "Important Notes:"
    echo "  • Credentials are stored in $RCLONE_CONF (root-only, chmod 600)"
    echo "  • Retention/folders can be changed anytime in $CONFIG_FILE"
    echo "  • The weekly/monthly copies are server-side in R2 (no extra upload traffic)"
    echo
}

# Main execution
main() {
    echo "=================================================="
    echo "   Cloudflare R2 Backup Sync Setup Script"
    echo "=================================================="
    echo

    check_root
    collect_r2_config
    install_rclone
    configure_rclone_remote
    test_r2_connection
    write_config
    deploy_push_script
    setup_cronjob
    display_summary
}

main "$@"
