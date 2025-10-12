#!/bin/bash

# PostgreSQL Backup Setup Script
# This script sets up automatic PostgreSQL backups with 7z compression
# Installs required packages, creates directories, sets permissions, and configures cron jobs

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to detect OS and install p7zip
install_p7zip() {
    print_status "Installing p7zip (7z) package..."
    
    if command -v yum >/dev/null 2>&1; then
        # RHEL/CentOS/AlmaLinux
        if yum list installed | grep -q "p7zip" 2>/dev/null; then
            print_success "p7zip is already installed"
        else
            print_status "Installing p7zip using yum..."
            yum install -y epel-release
            yum install -y p7zip p7zip-plugins
            print_success "p7zip installed successfully"
        fi
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora/newer RHEL
        if dnf list installed | grep -q "p7zip" 2>/dev/null; then
            print_success "p7zip is already installed"
        else
            print_status "Installing p7zip using dnf..."
            dnf install -y epel-release
            dnf install -y p7zip p7zip-plugins
            print_success "p7zip installed successfully"
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        if dpkg -l | grep -q "p7zip-full" 2>/dev/null; then
            print_success "p7zip is already installed"
        else
            print_status "Installing p7zip using apt-get..."
            apt-get update
            apt-get install -y p7zip-full
            print_success "p7zip installed successfully"
        fi
    else
        print_error "Unsupported package manager. Please install p7zip manually."
        exit 1
    fi
    
    # Verify installation
    if command -v 7za >/dev/null 2>&1; then
        print_success "7za command is available"
    else
        print_error "7za command not found after installation"
        exit 1
    fi
}

# Function to create backup directories
create_directories() {
    print_status "Creating backup directories..."
    
    BACKUP_DIR="/var/backups/postgresql"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        print_success "Created directory: $BACKUP_DIR"
    else
        print_success "Directory already exists: $BACKUP_DIR"
    fi
    
    # Set proper ownership and permissions
    chown postgres:postgres "$BACKUP_DIR"
    chmod 755 "$BACKUP_DIR"
    print_success "Set ownership and permissions for $BACKUP_DIR"
    
    # Create a logs subdirectory for better organization
    if [ ! -d "$BACKUP_DIR/logs" ]; then
        mkdir -p "$BACKUP_DIR/logs"
        chown postgres:postgres "$BACKUP_DIR/logs"
        chmod 755 "$BACKUP_DIR/logs"
        print_success "Created logs directory: $BACKUP_DIR/logs"
    fi
}

# Function to setup the backup script
setup_backup_script() {
    print_status "Setting up pg_backup.sh script..." >&2
    
    SCRIPT_DIR="/var/backups/postgresql"
    SCRIPT_PATH="$SCRIPT_DIR/pg_backup.sh"
    
    # Script directory is the same as backup directory (already created)
    print_success "Using backup directory as script directory: $SCRIPT_DIR" >&2
    
    # Check if pg_backup.sh exists in current directory
    if [ -f "./pg_backup.sh" ]; then
        print_status "Copying pg_backup.sh to $SCRIPT_PATH" >&2
        cp "./pg_backup.sh" "$SCRIPT_PATH"
    elif [ -f "pg_backup.sh" ]; then
        print_status "Copying pg_backup.sh to $SCRIPT_PATH" >&2
        cp "pg_backup.sh" "$SCRIPT_PATH"
    else
        print_error "pg_backup.sh not found in current directory" >&2
        print_error "Please ensure pg_backup.sh is in the same directory as this setup script" >&2
        exit 1
    fi
    
    # Make script executable
    chmod +x "$SCRIPT_PATH"
    chown root:root "$SCRIPT_PATH"
    print_success "Made pg_backup.sh executable and set ownership" >&2
    
    # Test the script syntax
    if bash -n "$SCRIPT_PATH"; then
        print_success "Script syntax validation passed" >&2
    else
        print_error "Script syntax validation failed" >&2
        exit 1
    fi
    
    echo "$SCRIPT_PATH"
}

# Function to setup cron job for India time (2:00 AM IST)
setup_cronjob() {
    local script_path="$1"
    print_status "Setting up cron job for 2:00 AM IST (India time)..."

    # Ensure tzdata exists
    if ! rpm -q tzdata >/dev/null 2>&1; then
        print_status "Installing timezone data..."
        dnf install -y tzdata || yum install -y tzdata
    fi

    # Ensure log directory exists
    mkdir -p /var/backups/postgresql/logs
    chown postgres:postgres /var/backups/postgresql/logs
    chmod 755 /var/backups/postgresql/logs

    print_status "Adding cron job to root's crontab..."

    # Prepare temporary file safely
    local TMP_CRON="/tmp/current_crontab_$$"
    
    # Initialize empty temp file
    > "$TMP_CRON"
    
    # Get existing crontab if it exists
    if crontab -l >/dev/null 2>&1; then
        crontab -l > "$TMP_CRON" 2>/dev/null
    fi

    # Remove old duplicate entries
    sed -i '/pg_backup\.sh/d' "$TMP_CRON" 2>/dev/null || true

    # Add new cron line
    echo "0 2 * * * $script_path >> /var/backups/postgresql/logs/cron_backup.log 2>&1" >> "$TMP_CRON"

    # Debug: Show what we're trying to install
    print_status "Cron job content to be installed:"
    cat "$TMP_CRON"
    echo "--- End of cron job content ---"
    
    # Validate before installing
    if crontab "$TMP_CRON" 2>/dev/null; then
        print_success "Cron job installed successfully"
    else
        print_error "Failed to install cron job — invalid syntax in $TMP_CRON"
        print_error "Cron job content:"
        cat "$TMP_CRON"
        rm -f "$TMP_CRON"
        exit 1
    fi

    rm -f "$TMP_CRON"

    # Ensure cron daemon is active
    if systemctl is-active --quiet crond; then
        print_success "Cron service is running"
    else
        print_status "Starting cron service..."
        systemctl enable --now crond
        print_success "Cron service started and enabled"
    fi

    print_success "Cron job configured to run daily at 2:00 AM IST (Asia/Kolkata timezone)"
}



# Function to display summary
display_summary() {
    echo
    print_success "=== PostgreSQL Backup Setup Complete ==="
    echo
    echo "Configuration Summary:"
    echo "  • Backup Directory: /var/backups/postgresql"
    echo "  • Script Location: /var/backups/postgresql/pg_backup.sh"
    echo "  • Schedule: Daily at 2:00 AM IST (Asia/Kolkata)"
    echo "  • Logs Directory: /var/backups/postgresql/logs"
    echo
    echo "Next Steps:"
    echo "  1. Test the backup manually: sudo /var/backups/postgresql/pg_backup.sh"
    echo "  2. Check cron job: crontab -l"
    echo "  3. Monitor logs: tail -f /var/backups/postgresql/logs/cron_backup.log"
    echo "  4. Verify backup files are created in /var/backups/postgresql/"
    echo
    print_warning "Important Notes:"
    echo "  • Backups run as root user with sudo to postgres"
    echo "  • Archive files are password protected (check pg_backup.sh for password)"
    echo "  • Old backup cleanup is commented out in the script (edit if needed)"
    echo "  • Ensure PostgreSQL is running and accessible on the configured port"
    echo
}

# Main execution
main() {
    echo "=================================================="
    echo "    PostgreSQL Backup System Setup Script"
    echo "=================================================="
    echo
    
    # Check if running as root
    check_root
    
    # Install required packages
    install_p7zip
    
    # Create directories
    create_directories
    
    # Setup backup script first
    script_path=$(setup_backup_script)
    
    # Setup cron job after script is ready
    setup_cronjob "$script_path"
    
    # Display summary
    display_summary
}

# Run main function
main "$@"