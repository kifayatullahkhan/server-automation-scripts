#!/usr/bin/env bash
#===============================================================================
#  Webmin Unattended Installer for Ubuntu 22 / 24 / 25
#-------------------------------------------------------------------------------
#  Author: Kifayat Khan (original), updated by Grok (xAI)
#  License: GNU GPL v3
#  Version: 1.6.0
#  Description:
#    Secure, fully automated Webmin installation script for Ubuntu systems.
#    Handles modern GPG keyring, HTTPS repository, firewall rules (UFW/firewalld),
#    and logs installation details. Fixed DSA-1024 weak key issue on Ubuntu 24.10+
#    with cleanup and reordered key/repo setup for curl-based execution.
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Global Variables
#------------------------------------------------------------------------------
LOG_FILE="/var/log/webmin-install.log"
INFO_FILE="/root/webmin-install-info.log"
WEBSERVER_PORT=10000
DATE_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXPECTED_KEY_FINGERPRINT="1719003ACE3E5A41E2DE70DFD97A3AE911F63C51"

#------------------------------------------------------------------------------
# Logging Function (displays on screen and logs to file)
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
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
if [[ "$UBUNTU_VERSION" =~ ^24\.10$ || "$UBUNTU_CODENAME" == "noble" ]]; then
    log "Detected Ubuntu 24.10 (noble). Enabling DSA-1024 workaround for Webmin key."
fi
if [[ ! "$UBUNTU_VERSION" =~ ^(22|24|25)\.[0-9]+$ ]]; then
    log "Warning: Detected Ubuntu $UBUNTU_VERSION — officially tested on 22.04/24.04/25.xx only."
fi

#------------------------------------------------------------------------------
# Cleanup Stale Webmin Config
#------------------------------------------------------------------------------
log "Cleaning up any existing Webmin repository or key files..."
rm -f /etc/apt/sources.list.d/webmin.list
rm -f /etc/apt/keyrings/webmin.gpg
rm -f /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf

#------------------------------------------------------------------------------
# Install Prerequisites
#------------------------------------------------------------------------------
log "Installing prerequisite packages..."
apt-get update -y 2>&1 | tee -a "$LOG_FILE"
apt-get install -y apt-transport-https software-properties-common curl wget gpg perl libnet-ssleay-perl 2>&1 | tee -a "$LOG_FILE"

# Optional: Skip full system upgrade to avoid unintended changes (uncomment to enable)
# apt-get upgrade -y 2>&1 | tee -a "$LOG_FILE"

#------------------------------------------------------------------------------
# Add Webmin GPG Key (Before Repository)
#------------------------------------------------------------------------------
log "Adding Webmin GPG key..."

mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings

# Download and convert Webmin GPG key with retry (max 3 attempts)
attempt=1
max_attempts=3
while [ $attempt -le $max_attempts ]; do
    log "Attempt $attempt of $max_attempts: Downloading Webmin GPG key..."
    if wget -qO- --tries=2 --timeout=10 https://download.webmin.com/developers-key.asc | gpg --dearmor > /etc/apt/keyrings/webmin.gpg; then
        log "Webmin GPG key imported successfully."
        break
    else
        log "Warning: Failed to download GPG key."
        if [ $attempt -eq $max_attempts ]; then
            log "Error: Failed to import Webmin GPG key after $max_attempts attempts."
            exit 1
        fi
        sleep 2
    fi
    ((attempt++))
done

# Verify GPG key import (check fingerprint)
KEY_FINGERPRINT=$(gpg --with-colons --show-keys /etc/apt/keyrings/webmin.gpg 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' | tr '[:lower:]' '[:upper:]')
if [[ "$KEY_FINGERPRINT" != "$EXPECTED_KEY_FINGERPRINT" ]]; then
    log "Error: Imported key fingerprint ($KEY_FINGERPRINT) does not match expected ($EXPECTED_KEY_FINGERPRINT)."
    exit 1
fi
log "GPG key fingerprint verified: $KEY_FINGERPRINT"

# Set secure permissions for keyring
chmod 644 /etc/apt/keyrings/webmin.gpg

# Apply DSA-1024 workaround for Ubuntu 24.10+
if [[ "$UBUNTU_CODENAME" == "noble" ]]; then
    log "Applying DSA-1024 allowance for Webmin key..."
    cat > /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf <<EOF
APT::Key::Assert-Pubkey-Algo "dsa1024=$EXPECTED_KEY_FINGERPRINT";
EOF
    chmod 644 /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf
fi

# Create Webmin APT source list (after key import)
echo "deb [signed-by=/etc/apt/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list
chmod 644 /etc/apt/sources.list.d/webmin.list

# Update repo and verify
log "Running apt-get update for Webmin repository..."
update_output=$(apt-get update -y 2>&1 | tee -a "$LOG_FILE")
if echo "$update_output" | grep -q "webmin.*Hit\|Get.*webmin"; then
    log "Webmin repository detected successfully."
elif echo "$update_output" | grep -iq "NO_PUBKEY\|signature.*invalid\|not signed"; then
    log "Error: GPG verification failed even with workaround. Falling back to official Webmin setup script..."
    # Fallback: Use official Webmin setup script
    cd /tmp
    if wget -q https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh && sh setup-repos.sh -y; then
        log "Official setup script succeeded. Proceeding with Webmin installation."
    else
        log "Error: Official fallback failed. Check $LOG_FILE or manual install at https://www.webmin.com/docs/modules/repository/."
        exit 1
    fi
else
    log "Warning: Could not fully verify Webmin repo. Continuing cautiously..."
fi

# Install Webmin
log "Installing Webmin..."
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y webmin --install-recommends 2>&1 | tee -a "$LOG_FILE"; then
    log "Error: Webmin installation failed. Check $LOG_FILE for details."
    exit 1
fi

#------------------------------------------------------------------------------
# Enable and Start Webmin Service
#------------------------------------------------------------------------------
log "Enabling and starting Webmin service..."
systemctl enable webmin 2>&1 | tee -a "$LOG_FILE"
systemctl restart webmin 2>&1 | tee -a "$LOG_FILE"
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
    ufw allow "$WEBSERVER_PORT"/tcp 2>&1 | tee -a "$LOG_FILE"
    ufw reload 2>&1 | tee -a "$LOG_FILE" || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    log "Configuring firewalld..."
    firewall-cmd --permanent --add-port="$WEBSERVER_PORT"/tcp 2>&1 | tee -a "$LOG_FILE"
    firewall-cmd --reload 2>&1 | tee -a "$LOG_FILE"
else
    log "No supported firewall (UFW or firewalld) detected; skipping configuration."
    log "Warning: Ensure port $WEBSERVER_PORT/tcp is open manually if a firewall is active."
fi

#------------------------------------------------------------------------------
# Cleanup (Remove DSA Workaround if Applied)
#------------------------------------------------------------------------------
if [[ -f /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf ]]; then
    rm -f /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf
    log "Cleaned up DSA-1024 workaround config."
fi

#------------------------------------------------------------------------------
# Log & Display Access Information
#------------------------------------------------------------------------------
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | tr ' ' '\n' | head -n 1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="localhost"
    log "Warning: Could not detect server IP. Using 'localhost' for access URL."
fi
ACCESS_URL="https://${SERVER_IP}:${WEBSERVER_PORT}/"

cat <<EOF | tee "$INFO_FILE"

============================================================
 ✅ Webmin Installation Completed Successfully!
============================================================

Date:          $DATE_NOW
Server:        $(hostname)
Ubuntu:        $(lsb_release -ds 2>/dev/null || echo "Unknown")
Webmin Port:   $WEBSERVER_PORT
Access URL:    $ACCESS_URL
Username:      root
Password:      (your existing root password)
Log File:      $LOG_FILE
Info File:     $INFO_FILE
Security Note: Webmin uses a self-signed SSL certificate by default.
               Consider configuring Let's Encrypt via Webmin's SSL module.
               DSA-1024 workaround applied and cleaned up for Ubuntu 24.10+.

============================================================
EOF

log "Webmin installation completed successfully."
log "Access URL: $ACCESS_URL"
log "Installation info saved at: $INFO_FILE"

exit 0