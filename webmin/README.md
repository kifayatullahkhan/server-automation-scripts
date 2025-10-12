# 🧰 Webmin Unattended Installer (Ubuntu 22–25 LTS)

This script installs the **latest stable version of Webmin** on any supported Ubuntu LTS server (22.04, 24.04, or 25.04+).  
It performs a **fully unattended**, **secure**, and **optimized** installation, ensuring Webmin is ready to use immediately after completion.

---

## 🚀 Features

- ✅ Fully unattended installation — no user input required.  
- 🔒 Secure setup — disables weak SSL/TLS versions and enforces HTTPS-only access.  
- 🧱 Compatible with **Ubuntu 22 / 24 / 25 LTS** (auto-detects version).  
- 🧾 Generates and stores installation logs + access info summary.  
- 🔄 Automatically updates APT packages before installation.  
- 🛠️ Configures firewall (UFW) rules to allow Webmin (port **10000**).  

---

## ⚙️ Usage

Run the following command as **root** or with `sudo` on a fresh Ubuntu server:

```bash
curl -fsSL https://raw.githubusercontent.com/kifayatullahkhan/server-automation-scripts/main/webmin/install_webmin.sh | sudo bash
