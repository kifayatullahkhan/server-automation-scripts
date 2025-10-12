#!/usr/bin/env bash
# install-webmin.sh — Unattended, hardened Webmin install for Ubuntu 22/24/25
# Usage:
#   sudo WEBMIN_PORT=10000 ADMIN_USER=admin ADMIN_PASS=MySecret \
#        ALLOW_IP="203.0.113.5,198.51.100.0/24" \
#        ./install-webmin.sh
#
# If ADMIN_PASS is omitted, a strong random password will be generated.
# If ALLOW_IP is provided, only those IPs/CIDRs will be permitted to access Webmin.
set -euo pipefail
IFS=$'\n\t'

# ---------- Configuration (can be overridden by env vars) ----------
WEBMIN_PORT="${WEBMIN_PORT:-10000}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
ALLOW_IP="${ALLOW_IP:-}"    # comma separated list of IPs/CIDRs (optional)
INFO_FILE="/root/webmin-install-info.json"
KEYRING="/usr/share/keyrings/webmin-archive-keyring.gpg"
APT_SRC="/etc/apt/sources.list.d/webmin.list"
MINISERV_PEM="/etc/webmin/miniserv.pem"
MINISERV_CONF="/etc/webmin/miniserv.conf"
LOG="/var/log/webmin-install.log"

# ---------- Helpers ----------
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() {
  echo "[$(timestamp)] $*" | tee -a "$LOG"
}
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
  fi
}
ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get install -yq "$pkg"
  fi
}

# ---------- Start ----------
require_root
log "Starting Webmin unattended installer"

# Non-interactive apt
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

log "Updating apt cache..."
apt-get update -yq

log "Installing prerequisite packages..."
apt-get install -yq --no-install-recommends \
  ca-certificates apt-transport-https gnupg curl wget openssl lsb-release ufw

# Add Webmin GPG key in keyring form (debian recommended)
if [ ! -f "$KEYRING" ]; then
  log "Adding Webmin GPG keyring..."
  wget -qO- https://download.webmin.com/jcameron-key.asc \
    | gpg --dearmor --batch --yes -o "$KEYRING"
fi

# Add apt source
if [ ! -f "$APT_SRC" ]; then
  log "Adding Webmin apt repository..."
  echo "deb [signed-by=${KEYRING}] https://download.webmin.com/download/repository sarge contrib" \
    > "$APT_SRC"
fi

log "apt-get update after adding Webmin repo..."
apt-get update -yq

# Install Webmin package
log "Installing Webmin package..."
apt-get install -yq webmin

# Ensure service is enabled
log "Enabling and starting webmin service..."
systemctl enable --now webmin

# Wait a bit for files to be created
sleep 1

# Generate admin password if not supplied
if [ -z "$ADMIN_PASS" ]; then
  # strong password, base64 but remove problematic characters
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=')"
  log "No ADMIN_PASS provided — generated a strong password for user '$ADMIN_USER'."
else
  log "Using provided ADMIN_PASS for user '$ADMIN_USER'."
fi

# Use changepass.pl to set admin password (works whether user exists or not)
if [ -x /usr/share/webmin/changepass.pl ]; then
  log "Setting Webmin admin password..."
  /usr/share/webmin/changepass.pl /etc/webmin "$ADMIN_USER" "$ADMIN_PASS" >/dev/null 2>&1
else
  log "ERROR: changepass.pl not found; aborting." >&2
  exit 1
fi

# Generate self-signed cert and write miniserv.pem (Webmin expects miniserv.pem)
log "Generating self-signed certificate for Webmin..."
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/webmin/miniserv.key \
  -out /etc/webmin/miniserv.crt \
  -subj "/CN=${HOSTNAME_FQDN}/O=Webmin Auto Install" >/dev/null 2>&1

# Combine to miniserv.pem and secure it
cat /etc/webmin/miniserv.key /etc/webmin/miniserv.crt > "$MINISERV_PEM"
chmod 600 "$MINISERV_PEM"
chown root:root "$MINISERV_PEM"
# Remove private key and crt duplicates (miniserv.pem contains both)
rm -f /etc/webmin/miniserv.key /etc/webmin/miniserv.crt

# Update miniserv.conf for port, SSL and allowed IPs
log "Configuring Webmin port and access control..."
# Ensure the config file exists
if [ ! -f "$MINISERV_CONF" ]; then
  log "ERROR: $MINISERV_CONF missing — aborting." >&2
  exit 1
fi

# Use awk or perl-safe update
perl -0777 -pe "s/\nport=\d+\n/\n/gs" -i "$MINISERV_CONF" || true
# Append or set port
if grep -q '^port=' "$MINISERV_CONF"; then
  sed -ri "s/^port=.*/port=${WEBMIN_PORT}/" "$MINISERV_CONF"
else
  echo "port=${WEBMIN_PORT}" >> "$MINISERV_CONF"
fi

# Ensure ssl=1
if grep -q '^ssl=' "$MINISERV_CONF"; then
  sed -ri "s/^ssl=.*/ssl=1/" "$MINISERV_CONF"
else
  echo "ssl=1" >> "$MINISERV_CONF"
fi

# Restrict allowed IPs if provided
if [ -n "$ALLOW_IP" ]; then
  # Webmin allows 'allow=' lines (comma or space separated); use comma->space
  ALLOWED_SPACE="$(echo "$ALLOW_IP" | tr ',' ' ')"
  if grep -q '^allow=' "$MINISERV_CONF"; then
    sed -ri "s|^allow=.*|allow=${ALLOWED_SPACE}|" "$MINISERV_CONF"
  else
    echo "allow=${ALLOWED_SPACE}" >> "$MINISERV_CONF"
  fi
  log "Configured access restriction: allow=${ALLOWED_SPACE}"
fi

# Restart webmin to pick changes
log "Restarting webmin service to apply TLS/port settings..."
systemctl restart webmin

# Configure UFW (if present). Do not disable other existing rules.
if command -v ufw >/dev/null 2>&1; then
  log "Configuring UFW to allow Webmin port ${WEBMIN_PORT}..."
  # If user specified ALLOW_IP, add rule(s) for those IPs only
  if [ -n "$ALLOW_IP" ]; then
    IFS=',' read -ra IPS <<< "$ALLOW_IP"
    for ip in "${IPS[@]}"; do
      ip="$(echo "$ip" | xargs)"
      if ! ufw status | grep -q "${WEBMIN_PORT}"; then
        ufw allow from "$ip" to any port "$WEBMIN_PORT" comment 'webmin'
      else
        ufw allow from "$ip" to any port "$WEBMIN_PORT" proto tcp comment 'webmin'
      fi
    done
  else
    ufw allow "${WEBMIN_PORT}/tcp" comment 'webmin'
  fi
  # Enable ufw if inactive (safe: only if it is currently inactive)
  UFW_STATUS="$(ufw status | head -n1 || true)"
  if echo "$UFW_STATUS" | grep -q "Status: inactive"; then
    log "UFW is inactive — enabling with existing rules."
    ufw --force enable
  fi
fi

# Gather certificate fingerprint for info file
CERT_FINGERPRINT="$(openssl x509 -noout -fingerprint -sha256 -in "$MINISERV_PEM" 2>/dev/null || true)"
# For readability reduce to hex only
CERT_FINGERPRINT="${CERT_FINGERPRINT#SHA256 Fingerprint=}"

# Save access info (JSON) with strict perms
log "Writing access information to ${INFO_FILE} (permissions 600)"
cat > "${INFO_FILE}.tmp" <<EOF
{
  "installed_at": "$(timestamp)",
  "hostname": "${HOSTNAME_FQDN}",
  "webmin_port": ${WEBMIN_PORT},
  "admin_user": "${ADMIN_USER}",
  "admin_pass": "${ADMIN_PASS}",
  "allow_ips": "$(echo ${ALLOW_IP})",
  "miniserv_pem": "${MINISERV_PEM}",
  "cert_fingerprint_sha256": "${CERT_FINGERPRINT}"
}
EOF
mv "${INFO_FILE}.tmp" "${INFO_FILE}"
chmod 600 "${INFO_FILE}"
chown root:root "${INFO_FILE}"

# Final check: is webmin listening on expected port?
if ss -tlnp | grep -q ":${WEBMIN_PORT}"; then
  BOUND=true
else
  BOUND=false
fi

# ---------- Finished ----------
log "Webmin installation completed."
cat <<EOF

==== Webmin installation summary ====

Access URL (HTTPS): https://${HOSTNAME_FQDN}:${WEBMIN_PORT}/
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASS}

Certificate (stored): ${MINISERV_PEM}
Certificate SHA256: ${CERT_FINGERPRINT}

Info saved to: ${INFO_FILE} (permissions 600)

Webmin service status: $(systemctl is-active webmin)   (enabled: $(systemctl is-enabled webmin))
Listening on port ${WEBMIN_PORT}: ${BOUND}

Firewall: $(command -v ufw >/dev/null 2>&1 && ufw status | sed -n '1,6p' || echo "ufw not present")

Important:
 - For production use with a real domain, replace the self-signed certificate with a Let's Encrypt certificate
   (or provide your own). After doing so, restart webmin: systemctl restart webmin
 - Keep ${INFO_FILE} secure. You can rotate the admin password with:
     sudo /usr/share/webmin/changepass.pl /etc/webmin ${ADMIN_USER} NEWPASSWORD

EOF

log "Done."
exit 0
