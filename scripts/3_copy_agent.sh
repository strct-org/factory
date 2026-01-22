#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Copying StructIO files..."

# 1. Copy the Service File
sudo cp ../overlay/etc/systemd/system/structio-agent.service $MOUNT_POINT/etc/systemd/system/

# 2. Copy the Go Binary
# IMPORTANT: You must have compiled this beforehand!
# GOOS=linux GOARCH=arm64 go build -o agent
if [ -f "../agent_binary" ]; then
    sudo cp ../agent_binary $MOUNT_POINT/usr/local/bin/agent
    sudo chmod +x $MOUNT_POINT/usr/local/bin/agent
else
    echo "ERROR: ../agent_binary not found. Did you compile it?"
    exit 1
fi

# 3. Enable the Service inside the image
echo "Enabling systemd service..."
sudo chroot $MOUNT_POINT systemctl enable structio-agent.service

echo "Files copied and service enabled."