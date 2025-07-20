#!/bin/bash

# ==============================================================================
#
# Script to install and configure PostgreSQL 17 on AlmaLinux 10.
#
# ==============================================================================

# --- Configuration ---
PG_VERSION="17"

# --- Colors for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
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

# --- Main Script ---
clear
echo "======================================================"
echo "  PostgreSQL ${PG_VERSION} Installer for AlmaLinux"
echo "======================================================"
echo

# --- Step 0: User Input ---
log_info "Please provide the following configuration details:"

read -p "Enter the port for PostgreSQL (e.g., 5432): " PG_PORT
if ! [[ "$PG_PORT" =~ ^[0-9]+$ ]] || [ "$PG_PORT" -lt 1 ] || [ "$PG_PORT" -gt 65535 ]; then
    log_error "Invalid port number. Aborting."
    exit 1
fi

read -p "Enter the IP address/range to whitelist (e.g., 192.168.1.50/32 or 0.0.0.0/0 for all): " WHITELIST_IP
if ! [[ "$WHITELIST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    log_error "Invalid IP address format. Aborting."
    exit 1
fi

read -s -p "Enter a new password for the 'postgres' database user: " POSTGRES_PASSWORD
echo
read -s -p "Confirm password: " POSTGRES_PASSWORD_CONFIRM
echo
if [[ "$POSTGRES_PASSWORD" != "$POSTGRES_PASSWORD_CONFIRM" ]] || [[ -z "$POSTGRES_PASSWORD" ]]; then
    log_error "Passwords do not match or are empty. Aborting."
    exit 1
fi

# Define file paths and service name
PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
PG_CONF_FILE="${PG_DATA_DIR}/postgresql.conf"
PG_HBA_FILE="${PG_DATA_DIR}/pg_hba.conf"
PG_SERVICE="postgresql-${PG_VERSION}"

# --- Step 1: Add PostgreSQL Repository ---
log_info "📁 Step 1: Adding PostgreSQL YUM repository..."
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
if [ $? -ne 0 ]; then log_error "Failed to add repository."; exit 1; fi

# --- Step 2: Disable Built-in PostgreSQL Module ---
log_info "❌ Step 2: Disabling the built-in PostgreSQL module..."
dnf -qy module disable postgresql
# if [ $? -ne 0 ]; then log_error "Failed to disable module."; exit 1; fi

# --- Step 3: Install PostgreSQL Packages ---
log_info "📦 Step 3: Installing PostgreSQL ${PG_VERSION} server and client..."
dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}
if [ $? -ne 0 ]; then log_error "Failed to install PostgreSQL packages."; exit 1; fi

dnf install -y postgresql17-contrib

# --- Step 4: Initialize Database Cluster ---
log_info "⚙️ Step 4: Initializing the database cluster..."
/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup initdb
if [ $? -ne 0 ]; then log_error "Failed to initialize the database cluster."; exit 1; fi

# --- Step 5: Enable and Start Service ---
log_info "🚀 Step 5: Enabling and starting the PostgreSQL service..."
systemctl enable --now ${PG_SERVICE}
if [ $? -ne 0 ]; then log_error "Failed to enable or start the PostgreSQL service."; exit 1; fi

# --- Step 6: Verify Service Status ---
log_info "🔍 Step 6: Verifying service status..."
if systemctl is-active --quiet ${PG_SERVICE}; then
    log_info "PostgreSQL service is active and running."
else
    log_error "PostgreSQL service failed to start. Check logs with 'journalctl -u ${PG_SERVICE}'."
    exit 1
fi

# --- Step 7: Set 'postgres' User Password ---
log_info "🔐 Step 7: Setting password for the 'postgres' user..."
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';"
if [ $? -ne 0 ]; then log_error "Failed to set password for the 'postgres' user."; exit 1; fi

# --- Step 8: Configure Remote Connections & Performance ---
log_info "📀 Step 8: Configuring for remote connections and performance..."

# Edit postgresql.conf
log_info "Updating ${PG_CONF_FILE}..."
# sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF_FILE"
# sed -i "s/^port = 5432/port = ${PG_PORT}/" "$PG_CONF_FILE"


sudo sed -i -E "s/^[# ]*listen_addresses\s*=.*/listen_addresses = '*'/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*port\s*=.*/port = ${PG_PORT}/g" "$PG_CONF_FILE"


# Memory settings
sudo sed -i -E "s/^[# ]*shared_buffers\s*=.*/shared_buffers = 500MB/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*work_mem\s*=.*/work_mem = 16MB/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*effective_cache_size\s*=.*/effective_cache_size = 2GB/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*maintenance_work_mem\s*=.*/maintenance_work_mem = 256MB/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*wal_buffers\s*=.*/wal_buffers = 16MB/g" "$PG_CONF_FILE"
sudo sed -i -E "s/^[# ]*random_page_cost\s*=.*/random_page_cost = 1.1/g" "$PG_CONF_FILE"


# # Append performance settings
# cat <<EOF >> "$PG_CONF_FILE"

# # --- Custom Settings Added By Script ---
# shared_buffers = 500MB
# work_mem = 16MB
# effective_cache_size = 2GB
# maintenance_work_mem = 256MB
# wal_buffers = 16MB
# random_page_cost = 1.1
# # --- End Custom Settings ---
# EOF

# Edit pg_hba.conf to allow remote connections
log_info "Updating ${PG_HBA_FILE} to allow access from ${WHITELIST_IP}..."
echo "host    all             all             ${WHITELIST_IP}        scram-sha-256" >> "$PG_HBA_FILE"

# --- Step 9: Configure Firewall ---
log_info "🔥 Step 9: Adding firewall rule for port ${PG_PORT}..."
firewall-cmd --zone=public --add-port=${PG_PORT}/tcp --permanent > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
if [ $? -ne 0 ]; then log_error "Failed to configure firewall."; exit 1; fi

# --- Final Restart to Apply All Changes ---
log_info "🔄 Restarting PostgreSQL to apply all configuration changes..."
systemctl restart ${PG_SERVICE}
if [ $? -ne 0 ]; then
    log_error "Failed to restart PostgreSQL. Check configuration and logs."
    exit 1
fi

# --- Completion Message ---
echo
log_info "✅ Done! PostgreSQL ${PG_VERSION} installation complete."
echo "---------------------------------------------------------"
echo "  Host:           $(hostname -I | awk '{print $1}')"
echo "  Port:           ${PG_PORT}"
echo "  Database User:  postgres"
echo "  Password:       [the one you set]"
echo "  Remote Access:  Allowed from ${WHITELIST_IP}"
echo "---------------------------------------------------------"