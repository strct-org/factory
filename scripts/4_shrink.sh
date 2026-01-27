#!/bin/bash
set -e

IMAGE_FILE="../work_image.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Syncing filesystem..."
sync

echo "Unmounting image..."

umount -lf $MOUNT_POINT/boot/firmware || true
umount -lf $MOUNT_POINT/boot || true
umount -lf $MOUNT_POINT/dev || true
umount -lf $MOUNT_POINT/proc || true
umount -lf $MOUNT_POINT/sys || true
umount -lf $MOUNT_POINT || true

losetup -D

echo "Finalizing image..."
sync

mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image is located at: $OUTPUT_FILE"