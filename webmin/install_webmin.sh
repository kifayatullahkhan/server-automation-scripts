#!/usr/bin/env bash
#===============================================================================
#  Webmin Unattended Installer for Ubuntu 22 / 24 / 25
#-------------------------------------------------------------------------------
#  Author: Kifayat Khan (original), updated by Grok (xAI)
#  License: GNU GPL v3
#  Version: 1.2.0
#  Description:
#    Secure, fully automated Webmin installation script for Ubuntu systems.
#    Handles modern GPG keyring, HTTPS repository, firewall rules (UFW/firewalld),
#    and logs installation details. Updated for 2025 Webmin key and compatibility.
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
    log "Error: This script must be run as root or with sudo."
    echo "Please run this script as root or with sudo."
    exit 1
fi

log "=== Starting Webmin unattended installation at $DATE_NOW ==="

#------------------------------------------------------------------------------
# Detect Ubuntu Version
#------------------------------------------------------------------------------
UBUNTU_VERSION=$(lsb_release -rs)
if [[ ! "$UBUNTU_VERSION" =~ ^(22|24|25)\.[0-9]+$ ]]; then
    log "Warning: Detected Ubuntu $UBUNTU_VERSION — officially tested on 22.04/24.04/25.xx LTS only."
fi

#------------------------------------------------------------------------------
# Install Prerequisites
#------------------------------------------------------------------------------
log "Installing prerequisite packages..."
apt-get update -y >>"$LOG_FILE" 2>&1
apt-get install -y apt-transport-https software-properties-common curl wget gpg >>"$LOG_FILE" 2>&1

# Optional: Skip full system upgrade to avoid unintended changes (uncomment to enable)
# apt-get upgrade -y >>"$LOG_FILE" 2>&1

#------------------------------------------------------------------------------
# Add Webmin Repository (Secure Key Handling)
#------------------------------------------------------------------------------
log "Adding Webmin GPG key and repository..."

mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings

# Download and convert Webmin GPG key to keyring format (using current developers key over HTTPS)
if wget -qO- https://download.webmin.com/developers-key.asc | gpg --dearmor > /etc/apt/keyrings/webmin.gpg; then
    log "Webmin GPG key imported successfully."
else
    log "Error: Failed to import Webmin GPG key from https://download.webmin.com/developers-key.asc."
    exit 1
fi

# Set secure permissions for keyring
chmod 644 /etc/apt/keyrings/webmin.gpg

# Create Webmin APT source list
echo "deb [signed-by=/etc/apt/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list
chmod 644 /etc/apt/sources.list.d/webmin.list

# Update repo and verify
log "Running apt-get update for Webmin repository..."
update_output=$(apt-get update -y 2>&1 | tee -a "$LOG_FILE")
if echo "$update_output" | grep -q "webmin"; then
    log "Webmin repository detected successfully."
elif echo "$update_output" | grep -iq "NO_PUBKEY\|signature"; then
    log "Error: GPG key verification failed. Check key URL or official docs at https://www.webmin.com."
    exit 1
else
    log "Warning: Could not verify Webmin repo signature. Continuing cautiously..."
fi

# Install Webmin
log "Installing Webmin..."
DEBIAN_FRONTEND=noninteractive apt-get install -y webmin >>"$LOG_FILE" 2>&1

#------------------------------------------------------------------------------
# Enable and Start Webmin Service
#------------------------------------------------------------------------------
log "Enabling and starting Webmin service..."
systemctl enable webmin >>"$LOG_FILE" 2>&1
systemctl restart webmin >>"$LOG_FILE" 2>&1
if systemctl is-active --quiet webmin; then
    log "Webmin service started successfully."
else
    log "Error: Webmin service failed to start. Check $LOG_FILE for details."
    exit 1
fi

#------------------------------------------------------------------------------
# Configure Firewall
#------------------------------------------------------------------------------
log "Configuring firewall..."
if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW firewall..."
    ufw allow "$WEBSERVER_PORT"/tcp >>"$LOG_FILE" 2>&1
    ufw reload >>"$LOG_FILE" 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    log "Configuring firewalld..."
    firewall-cmd --permanent --add-port="$WEBSERVER_PORT"/tcp >>"$LOG_FILE" 2>&1
    firewall-cmd --reload >>"$LOG_FILE" 2>&1
else
    log "No supported firewall (UFW or firewalld) detected; skipping configuration."
    log "Warning: Ensure port $WEBSERVER_PORT/tcp is open manually if a firewall is active."
fi

#------------------------------------------------------------------------------
# Log & Display Access Information
#------------------------------------------------------------------------------
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
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
Security Note: Webmin uses a self-signed SSL certificate by default.
               Consider configuring Let's Encrypt via Webmin's SSL module.

============================================================
EOF

log "Webmin installation completed successfully."
log "Access URL: $ACCESS_URL"
log "Installation info saved at: $INFO_FILE"

exit 0