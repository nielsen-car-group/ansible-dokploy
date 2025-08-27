#!/bin/bash
set -e

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root or with sudo."
  exit 1
fi

# Default to the user who invoked sudo (if any), otherwise $USER
TARGET_USER=${SUDO_USER:-$USER}

echo "👤 Adding user '$TARGET_USER' to the docker group..."
# Ensure docker group exists
if ! getent group docker > /dev/null 2>&1; then
  echo "⚠️  'docker' group does not exist, creating it..."
  groupadd docker
fi
# Add the user
usermod -aG docker "$TARGET_USER"
echo "✅ User '$TARGET_USER' added to the docker group."

echo ""
echo "👤 Adding user '$TARGET_USER' to the dokploy-logs group..."
# Ensure dokploy-logs group exists
if ! getent group dokploy-logs > /dev/null 2>&1; then
  echo "⚠️ 'dokploy-logs' group does not exist, creating it..."
  groupadd dokploy-logs
fi

# Ensure /etc/dokploy/logs exists and set group ownership
mkdir -p /etc/dokploy/logs
chgrp -R dokploy-logs /etc/dokploy/logs
chmod -R 775 /etc/dokploy/logs

# Add the user
usermod -aG dokploy-logs "$TARGET_USER"
echo "✅ User '$TARGET_USER' added to the dokploy-logs group."

echo ""
echo "⚠️ IMPORTANT: You need to log out and log back in (or run 'newgrp docker' and 'newgrp dokploy-logs')"
echo "   for the changes to take effect."
