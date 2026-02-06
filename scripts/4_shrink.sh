#!/bin/bash
set -e

IMAGE_FILE="../work_image.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Syncing filesystem..."
sync

echo "Unmounting image..."
# Lazy unmount everything under the mountpoint
umount -R $MOUNT_POINT || true

# Detach loop devices
losetup -D

echo "Finalizing image..."
sync
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image is located at: $OUTPUT_FILE"