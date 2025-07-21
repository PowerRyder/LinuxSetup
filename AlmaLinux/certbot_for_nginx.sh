#!/bin/bash

# ==============================================================================
#
# Script to create a cron job for Certbot automatic renewal if one
# does not already exist.
#
# ==============================================================================

# --- Colors for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# --- Pre-flight Checks ---
# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Please use 'sudo'."
   exit 1
fi


sudo dnf install certbot python3-certbot-nginx -y

# Find the certbot executable path
CERTBOT_PATH=$(which certbot)
if [[ -z "$CERTBOT_PATH" ]]; then
    log_error "Certbot executable not found. Please ensure Certbot is installed correctly."
    exit 1
fi

# --- Main Script ---
clear
echo "======================================================"
echo "  Certbot Automatic Renewal Cron Job Setup"
echo "======================================================"
echo

# --- Check for existing renewal methods ---
log_info "Checking for existing renewal configurations..."

if systemctl list-unit-files | grep -q "certbot.timer"; then
    log_warn "A 'certbot.timer' systemd unit already exists. No action needed."
    log_warn "Your system is likely already configured for automatic renewals."
    exit 0
fi

if [[ -f /etc/cron.d/certbot ]]; then
    log_warn "A '/etc/cron.d/certbot' file already exists. No action needed."
    log_warn "Your system is likely already configured for automatic renewals."
    exit 0
fi

log_info "No standard systemd timer or cron.d file found. Checking user crontab..."

# --- Check for and add the cron job if needed ---
CRON_JOB_COMMAND="$CERTBOT_PATH renew --quiet"
CRON_SCHEDULE="17 2,14 * * *" # Runs at 2:17 AM and 2:14 PM daily
FULL_CRON_JOB="$CRON_SCHEDULE $CRON_JOB_COMMAND"

# Check if the exact cron job already exists for the root user
if crontab -l -u root 2>/dev/null | grep -Fq -- "$CRON_JOB_COMMAND"; then
    log_warn "A cron job for Certbot renewal already exists in the root crontab. No action needed."
    exit 0
fi

# If we reach here, no renewal method was found. Let's add one.
log_info "No renewal job found. Adding a new cron job for root..."

# Use a temporary file to safely add the new job
(crontab -l -u root 2>/dev/null; echo "$FULL_CRON_JOB") | crontab -u root -

if [ $? -eq 0 ]; then
    log_info "Successfully added the following cron job:"
    echo "  $FULL_CRON_JOB"
else
    log_error "Failed to add the cron job."
    exit 1
fi

# --- Final Verification ---
echo
log_info "✅ Done! A cron job has been set up for automatic renewal."
log_info "As a final check, it's highly recommended to run a dry run:"
log_warn "  sudo certbot renew --dry-run"