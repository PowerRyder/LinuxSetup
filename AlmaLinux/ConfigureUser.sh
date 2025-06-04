#!/bin/bash

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Exiting." 
   exit 1
fi
# Step 1: Install EPEL
echo "Installing epel-release..."
dnf install epel-release -y

# Step 2: Set root password
echo "Set root password:"
passwd

# Prompt for username
read -p "Enter the username you want to create: " USERNAME

# Step 3: Create user and set password
echo "Creating user '$USERNAME'..."
adduser "$USERNAME"
echo "Set password for '$USERNAME':"
passwd "$USERNAME"

# Step 4: Grant passwordless sudo access
echo "Granting passwordless sudo access to '$USERNAME'..."
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

echo "Configuration complete for user '$USERNAME'."



