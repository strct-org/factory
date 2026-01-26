#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

AGENT_VERSION="v1.0.0"
DOWNLOAD_URL="https://github.com/strct-org/structio-agent/releases/download/${AGENT_VERSION}/structio-agent-arm64"

echo "Copying Strct files..."

sudo cp ../overlay/etc/systemd/system/strct_agent.service $MOUNT_POINT/etc/systemd/system/

echo "⬇ Downloading Agent ${AGENT_VERSION} from GitHub..."

wget -q --show-progress -O agent_binary "$DOWNLOAD_URL"

if [ ! -s "agent_binary" ]; then
    echo "Error: Download failed or file is empty."
    exit 1
fi

sudo mv agent_binary $MOUNT_POINT/usr/local/bin/agent
sudo chmod +x $MOUNT_POINT/usr/local/bin/agent

echo "Enabling systemd service..."
sudo chroot $MOUNT_POINT systemctl enable strct_agent.service

echo " Agent ${AGENT_VERSION} installed successfully."