#!/bin/bash
set -e

IMAGE_FILE="../raspberrypi.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Unmounting image..."

umount $MOUNT_POINT/boot || true
umount $MOUNT_POINT/dev || true
umount $MOUNT_POINT/proc || true
umount $MOUNT_POINT/sys || true
umount $MOUNT_POINT || true

# Detach loop device
losetup -D

echo "Shrinking image using PiShrink..."

# Download PiShrink if not present
if [ ! -f "pishrink.sh" ]; then
    wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
    chmod +x pishrink.sh
fi

./pishrink.sh "$IMAGE_FILE" "$OUTPUT_FILE"

echo "DONE! Final image is located at: $OUTPUT_FILE"