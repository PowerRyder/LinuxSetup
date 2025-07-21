#!/bin/bash

# ==============================================================================
#
# Script to install and set up Docker Engine on AlmaLinux and other
# RHEL-based systems.
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

# --- Main Script ---
clear
echo "======================================================"
echo "  Docker Engine Installer for RHEL-based Systems"
echo "======================================================"
echo

# --- Step 1: Remove Old Versions ---
log_info "Step 1: Removing any old Docker versions..."
dnf remove docker \
            docker-client \
            docker-client-latest \
            docker-common \
            docker-latest \
            docker-latest-logrotate \
            docker-logrotate \
            docker-engine -y > /dev/null 2>&1
log_info "Old versions removed."

# --- Step 2: Set Up the Docker Repository ---
log_info "Step 2: Setting up the official Docker repository..."
dnf install -y dnf-utils > /dev/null
if [ $? -ne 0 ]; then log_error "Failed to install dnf-utils."; exit 1; fi

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
if [ $? -ne 0 ]; then log_error "Failed to add Docker repository."; exit 1; fi
log_info "Docker repository added successfully."

# --- Step 3: Install Docker Engine ---
log_info "Step 3: Installing Docker Engine..."
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if [ $? -ne 0 ]; then
    log_error "Failed to install Docker packages. Please check for errors."
    exit 1
fi
log_info "Docker Engine installed successfully."

# --- Step 4: Start and Enable Docker Service ---
log_info "Step 4: Starting and enabling the Docker service..."
systemctl start docker
if [ $? -ne 0 ]; then log_error "Failed to start Docker service."; exit 1; fi

systemctl enable docker
if [ $? -ne 0 ]; then log_error "Failed to enable Docker service."; exit 1; fi
log_info "Docker service is active and enabled on boot."

# --- Step 5: Add User to Docker Group (Optional) ---
read -p "Do you want to run Docker without 'sudo'? (y/N): " allow_no_sudo
if [[ "$allow_no_sudo" =~ ^[Yy]$ ]]; then
    # Get the user who invoked sudo, or fall back to the current user
    SUDO_USER=${SUDO_USER:-$USER}
    log_info "Adding user '$SUDO_USER' to the 'docker' group..."
    usermod -aG docker "$SUDO_USER"
    if [ $? -eq 0 ]; then
        log_warn "User '$SUDO_USER' added to the 'docker' group."
        log_warn "You must log out and log back in for this change to take effect!"
    else
        log_error "Failed to add user to the 'docker' group."
    fi
fi

# --- Completion Message ---
echo
log_info "✅ Done! Docker installation is complete."
echo "---------------------------------------------------------"
echo "  To verify your installation, run:"
log_warn "    sudo docker run hello-world"
echo
echo "  If you added your user to the 'docker' group, log out"
echo "  and log back in, then you can run:"
log_warn "    docker run hello-world"
echo "---------------------------------------------------------"