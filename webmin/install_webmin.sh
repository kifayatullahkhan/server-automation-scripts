#!/usr/bin/env bash
#===============================================================================
#  Webmin Unattended Installer for Ubuntu 22 / 24 / 25
#-------------------------------------------------------------------------------
#  Author: Kifayat Khan (original)
#  License: GNU GPL v3
#  Version: 1.13.0
#  Description:
#    Secure, fully automated Webmin installation script for Ubuntu systems.
#    Handles DSA-1024 key (jcameron-key.asc) for sarge repo, with robust APT
#    handling and fallback to official Webmin script. Optimized for Ubuntu 24.10+
#    and unattended multi-server deployment.
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
    log "Detected Ubuntu 24.10 (noble). Enabling DSA-1024 allowance for Webmin key."
fi
if [[ ! "$UBUNTU_VERSION" =~ ^(22|24|25)\.[0-9]+$ ]]; then
    log "Warning: Detected Ubuntu $UBUNTU_VERSION — officially tested on 22.04/24.04/25.xx only."
fi

#------------------------------------------------------------------------------
# Cleanup Stale Webmin Config and APT Cache
#------------------------------------------------------------------------------
log "Cleaning up any existing Webmin repository or key files..."
rm -f /etc/apt/sources.list.d/webmin.list
rm -f /etc/apt/keyrings/webmin.gpg
rm -f /etc/apt/trusted.gpg.d/webmin-allow-dsa.conf
rm -rf /var/lib/apt/lists/*webmin*
rm -rf /var/lib/apt/lists/*  # Full cache clear for robustness

#------------------------------------------------------------------------------
# Install Prerequisites
#------------------------------------------------------------------------------
log "Installing prerequisite packages..."
apt-get update -y 2>&1 | tee -a "$LOG_FILE"
apt-get install -y apt-transport-https software-properties-common curl wget gpg perl libnet-ssleay-perl 2>&1 | tee -a "$LOG_FILE"

#------------------------------------------------------------------------------
# Add Webmin GPG Key (Before Repository)
#------------------------------------------------------------------------------
log "Adding Webmin GPG key..."

mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings

# Download and convert Webmin GPG key with retry (max 5 attempts)
attempt=1
max_attempts=5
while [ $attempt -le $max_attempts ]; do
    log "Attempt $attempt of $max_attempts: Downloading Webmin GPG key..."
    if wget -qO- --tries=3 --timeout=15 https://www.webmin.com/jcameron-key.asc | gpg --dearmor > /etc/apt/keyrings/webmin.gpg; then
        log "Webmin GPG key imported successfully."
        break
    else
        log "Warning: Failed to download GPG key."
        if [ $attempt -eq $max_attempts ]; then
            log "Error: Failed to import Webmin GPG key after $max_attempts attempts."
            exit 1
        fi
        sleep 3
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

# Create Webmin APT source list
echo "deb [signed-by=/etc/apt/keyrings/webmin.gpg] http://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list
chmod 644 /etc/apt/sources.list.d/webmin.list

# DSA-1024 allowance for Ubuntu 24.10+
if [[ "$UBUNTU_CODENAME" == "noble" ]]; then
    log "Applying DSA-1024 allowance for Webmin key..."
    cat > /etc/apt/apt.conf.d/99webmin-allow-dsa <<EOF
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
Acquire::http::AllowSignatureMismatch "true";
Acquire::https::AllowSignatureMismatch "true";
Acquire::AllowInsecureRepositories::webmin "true";
EOF
    chmod 644 /etc/apt/apt.conf.d/99webmin-allow-dsa
fi

# Test network connectivity to Webmin repo
log "Testing network connectivity to Webmin repository..."
attempt=1
max_attempts=5
while [ $attempt -le $max_attempts ]; do
    log "Attempt $attempt of $max_attempts: Checking http://download.webmin.com/download/repository/dists/sarge/Release..."
    if curl -s --connect-timeout 5 --head http://download.webmin.com/download/repository/dists/sarge/Release | grep -q "200 OK"; then
        log "Webmin repository URL is reachable."
        break
    else
        log "Warning: Cannot reach Webmin repository."
        if [ $attempt -eq $max_attempts ]; then
            log "Error: Cannot reach Webmin repository after $max_attempts attempts. Falling back to official script..."
            cd /tmp
            if wget -q https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh && sh webmin-setup-repo.sh --force; then
                log "Official setup script succeeded. Proceeding with Webmin installation."
                break
            else
                log "Error: Official fallback failed. Check $LOG_FILE or manual install at https://www.webmin.com."
                exit 1
            fi
        fi
        sleep 3
    fi
    ((attempt++))
done

# Update repo with retry (max 5 attempts)
log "Running apt-get update for Webmin repository..."
attempt=1
max_attempts=5
while [ $attempt -le $max_attempts ]; do
    log "Attempt $attempt of $max_attempts: Updating APT with Webmin repository..."
    rm -rf /var/lib/apt/lists/*webmin*
    tmp_output=$(mktemp)
    if timeout 180 apt-get update -y > "$tmp_output" 2>&1; then
        update_output=$(cat "$tmp_output")
        echo "$update_output" | tee -a "$LOG_FILE"
        log "APT update completed successfully."
        rm -f "$tmp_output"
        break
    else
        update_output=$(cat "$tmp_output")
        echo "$update_output" | tee -a "$LOG_FILE"
        log "Warning: APT update failed on attempt $attempt. Full output logged to $LOG_FILE."
        if [ $attempt -eq $max_attempts ]; then
            log "Falling back to official Webmin setup script..."
            cd /tmp
            if wget -q https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh && sh webmin-setup-repo.sh --force; then
                log "Official setup script succeeded. Proceeding with Webmin installation."
                rm -f "$tmp_output"
                break
            else
                log "Error: Official fallback failed. Check $LOG_FILE or manual install at https://www.webmin.com."
                rm -f "$tmp_output"
                exit 1
            fi
        fi
        rm -f "$tmp_output"
        sleep 3
    fi
    ((attempt++))
done

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
# Cleanup DSA Workaround
#------------------------------------------------------------------------------
if [[ -f /etc/apt/apt.conf.d/99webmin-allow-dsa ]]; then
    rm -f /etc/apt/apt.conf.d/99webmin-allow-dsa
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
