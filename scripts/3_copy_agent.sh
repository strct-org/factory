#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

AGENT_VERSION="v1.0.1"
# Ensure this matches the binary name in your GitHub Release
BINARY_NAME="strct-agent-arm64" 
DOWNLOAD_URL="https://github.com/strct-org/structio-agent/releases/download/${AGENT_VERSION}/${BINARY_NAME}"

echo "Creating Service File..."
cat <<EOF > strct_agent.service
[Unit]
Description=Strct Agent
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/agent
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "Copying Service file to image..."
cp strct_agent.service $MOUNT_POINT/etc/systemd/system/

echo "⬇ Downloading Agent ${AGENT_VERSION}..."
wget -q --show-progress -O agent_binary "$DOWNLOAD_URL"

if [ ! -s "agent_binary" ]; then
    echo "❌ Error: Download failed or file is empty."
    exit 1
fi

mv agent_binary $MOUNT_POINT/usr/local/bin/agent
chmod +x $MOUNT_POINT/usr/local/bin/agent

echo "Enabling systemd service..."
chroot $MOUNT_POINT systemctl enable strct_agent.service

rm strct_agent.service

echo "Agent ${AGENT_VERSION} installed successfully."