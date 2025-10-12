#!/usr/bin/env bash
#===============================================================================
#  Webmin Unattended Installer for Ubuntu 22 / 24 / 25 LTS
#-------------------------------------------------------------------------------
#  Author: Kifayat Khan
#  License: GNU GPL v3
#  Version: 1.1.0
#  Description:
#    Secure, fully automated Webmin installation script with modern GPG key
#    handling for Ubuntu systems. Automatically sets up HTTPS access, UFW rules,
#    and logs installation details for later reference.
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Global Variables
#------------------------------------------------------------------------------
LOG_FILE="/var/log/webmin-install.log"
INFO_FILE="/root/webmin-install-info.log"
WEBSERVER_PORT=10000
DATE_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

#------------------------------------------------------------------------------
# Logging Function
#------------------------------------------------------------------------------
log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Pre-flight Checks
#------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root or with sudo."
    exit 1
fi

log "=== Starting Webmin unattended installation at $DATE_NOW ==="

#------------------------------------------------------------------------------
# Detect Ubuntu Version
#------------------------------------------------------------------------------
UBUNTU_VERSION=$(lsb_release -rs | cut -d'.' -f1)
if [[ ! "$UBUNTU_VERSION" =~ ^(22|24|25)$ ]]; then
    log "Warning: Detected Ubuntu $UBUNTU_VERSION — officially tested on 22/24/25 LTS only."
fi

#------------------------------------------------------------------------------
# Update System Packages
#------------------------------------------------------------------------------
log "Updating package lists and upgrading system..."
apt-get update -y >>"$LOG_FILE" 2>&1
apt-get upgrade -y >>"$LOG_FILE" 2>&1
apt-get install -y apt-transport-https software-properties-common curl wget gpg >>"$LOG_FILE" 2>&1

#------------------------------------------------------------------------------
# Add Webmin Repository (Secure Key Handling)
#------------------------------------------------------------------------------
log "Adding Webmin GPG key and repository..."

mkdir -p /etc/apt/keyrings

# Download and convert Webmin GPG key to keyring format
if wget -qO- http://www.webmin.com/jcameron-key.asc | gpg --dearmor > /etc/apt/keyrings/webmin.gpg; then
    log "Webmin GPG key imported successfully."
else
    log "Error: Failed to import Webmin GPG key."
    exit 1
fi

# Create Webmin APT source list
echo "deb [signed-by=/etc/apt/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list

# Update repo and install Webmin
log "Running apt-get update for Webmin repository..."
if apt-get update -y | tee -a "$LOG_FILE" | grep -q "webmin"; then
    log "Webmin repository detected successfully."
else
    log "Warning: Could not verify Webmin repo signature. Continuing cautiously..."
fi

log "Installing Webmin..."
DEBIAN_FRONTEND=noninteractive apt-get install -y webmin >>"$LOG_FILE" 2>&1

#------------------------------------------------------------------------------
# Enable and Start Webmin Service
#------------------------------------------------------------------------------
systemctl enable webmin >>"$LOG_FILE" 2>&1
systemctl restart webmin >>"$LOG_FILE" 2>&1

#------------------------------------------------------------------------------
# Configure Firewall
#------------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW firewall..."
    ufw allow "$WEBSERVER_PORT"/tcp >>"$LOG_FILE" 2>&1 || true
else
    log "UFW not installed; skipping firewall configuration."
fi

#------------------------------------------------------------------------------
# Log & Display Access Information
#------------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
ACCESS_URL="https://${SERVER_IP}:${WEBSERVER_PORT}/"

cat <<EOF | tee "$INFO_FILE"

============================================================
 ✅ Webmin Installation Completed Successfully!
============================================================

Date:          $DATE_NOW
Server:        $(hostname)
Ubuntu:        $(lsb_release -ds)
Webmin Port:   $WEBSERVER_PORT
Access URL:    $ACCESS_URL
Username:      root
Password:      (your existing root password)
Log File:      $LOG_FILE
Info File:     $INFO_FILE

============================================================
EOF

log "Webmin installation completed successfully."
log "Access URL: $ACCESS_URL"
log "Installation info saved at: $INFO_FILE"

exit 0
