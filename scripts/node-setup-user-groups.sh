#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root or with sudo."
  exit 1
fi

TARGET_USER=${SUDO_USER:-$USER}

echo "🔧 Ensuring 'acl' package is installed (for setfacl)..."
if ! command -v setfacl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y acl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y acl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y acl
  fi
fi

# Docker group
echo "👤 Adding user '$TARGET_USER' to the docker group..."
getent group docker >/dev/null 2>&1 || groupadd docker
usermod -aG docker "$TARGET_USER"

# Dokploy groups
echo "👥 Ensuring dokploy groups exist..."
getent group dokploy >/dev/null 2>&1 || groupadd dokploy
getent group dokploy-logs >/dev/null 2>&1 || groupadd dokploy-logs

echo "📁 Preparing /etc/dokploy base dirs..."
mkdir -p /etc/dokploy/compose
mkdir -p /etc/dokploy/logs

# Ownership + setgid so new files inherit the group
chown -R root:dokploy /etc/dokploy/compose
chown -R root:dokploy-logs /etc/dokploy/logs
chmod 2775 /etc/dokploy/compose
chmod 2775 /etc/dokploy/logs

# ACLs so group always has rwx on new files/dirs
setfacl -R -m g:dokploy:rwx /etc/dokploy/compose
setfacl -dR -m g:dokploy:rwx /etc/dokploy/compose

setfacl -R -m g:dokploy-logs:rwx /etc/dokploy/logs
setfacl -dR -m g:dokploy-logs:rwx /etc/dokploy/logs

# Add the deploy user to both groups
usermod -aG dokploy "$TARGET_USER"
usermod -aG dokploy-logs "$TARGET_USER"

echo "✅ User '$TARGET_USER' added to groups: docker, dokploy, dokploy-logs."
echo "⚠️  IMPORTANT: log out and back in (or run 'newgrp docker' then 'newgrp dokploy') to apply group membership."

