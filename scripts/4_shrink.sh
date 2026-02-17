#!/bin/bash
set -euo pipefail

IMAGE_FILE="../work_image.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Syncing filesystem..."
sync

echo "Unmounting image..."
umount -R "$MOUNT_POINT" || true

losetup -D

sync
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image is located at: $OUTPUT_FILE"
