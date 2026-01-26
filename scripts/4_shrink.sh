#!/bin/bash

set -e

IMAGE_FILE="raspberry_pi_server.img" #! change to orange.pi
MOUNT_POINT="mnt_root"

echo "Unmounting image..."

# Unmount everything
sudo umount $MOUNT_POINT/boot || true
sudo umount $MOUNT_POINT/dev || true
sudo umount $MOUNT_POINT/proc || true
sudo umount $MOUNT_POINT/sys || true
sudo umount $MOUNT_POINT || true

# Detach loop device
sudo losetup -D

echo "Shrinking image using PiShrink..."

# Download PiShrink if not present
if [ ! -f "pishrink.sh" ]; then
    wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
    chmod +x pishrink.sh
fi

# Run it
sudo ./pishrink.sh $IMAGE_FILE strct-release-v1.img

echo "DONE! Ready to flash: strct-release-v1.img"