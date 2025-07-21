#!/bin/bash

# ==============================================================================
#
# Script to prepare a system for shared Docker services by:
#   1. Installing the 'unzip' utility.
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
echo "  Shared Services Prerequisite Installer"
echo "======================================================"
echo

# Install unzip
log_info "Installing 'unzip' utility..."
if command -v unzip &> /dev/null; then
    log_warn "'unzip' is already installed. Skipping."
else
    dnf install -y unzip
    if [ $? -ne 0 ]; then
        log_error "Failed to install 'unzip'. Please check for errors."
        exit 1
    fi
    log_info "'unzip' installed successfully."
fi

# --- Completion Message ---
echo
log_info "✅ Done! Your system is now ready."
echo "---------------------------------------------------------"
echo "  - The 'unzip' utility is installed."
echo "---------------------------------------------------------"
