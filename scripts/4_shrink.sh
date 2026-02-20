#!/bin/bash
set -e

IMAGE_FILE="../work_image.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Syncing filesystem..."
sync

echo "Unmounting image partitions..."
umount -lf "$MOUNT_POINT/boot/firmware" 2>/dev/null || true
umount -lf "$MOUNT_POINT/boot"          2>/dev/null || true
umount -lf "$MOUNT_POINT/dev"           2>/dev/null || true
umount -lf "$MOUNT_POINT/proc"          2>/dev/null || true
umount -lf "$MOUNT_POINT/sys"           2>/dev/null || true
umount -lf "$MOUNT_POINT"              2>/dev/null || true
sync

echo "Detaching all loop devices..."
losetup -D

# ---------------------------------------------------------------------------
# Shrink the filesystem.
# The old script just moved the file, leaving ~2GB of empty space.
# ---------------------------------------------------------------------------
echo "Shrinking filesystem..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")

echo "  Running fsck before resize..."
e2fsck -f -y "${LOOP_DEV}p2"

echo "  Shrinking ext4 to minimum size..."
resize2fs -M "${LOOP_DEV}p2"

# Calculate exact byte size of the shrunk partition
BLOCK_SIZE=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block size:/{print $3}')
BLOCK_COUNT=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block count:/{print $3}')
P2_START=$(parted -m "$IMAGE_FILE" unit B print \
    | awk -F: '/^2:/{gsub("B",""); print $2}')

FS_SIZE=$(( BLOCK_SIZE * BLOCK_COUNT ))
# Add 1 MiB alignment buffer so parted doesn't complain
NEW_END=$(( P2_START + FS_SIZE + 1048576 ))
NEW_IMG_SIZE=$(( NEW_END + 512 ))

echo "  P2 start:    ${P2_START} B"
echo "  FS size:     ${FS_SIZE} B"
echo "  New P2 end:  ${NEW_END} B"
echo "  New img:     $(( NEW_IMG_SIZE / 1024 / 1024 )) MB"

# parted -s = script mode (no interactive prompts, no "are you sure?")
# This is what was causing the "Error: Process completed with exit code 1" —
# parted was waiting for user input that never came in CI.
echo "  Resizing partition table (script mode, no prompts)..."
parted -s "$IMAGE_FILE" resizepart 2 "${NEW_END}B"

losetup -d "$LOOP_DEV"
sync

echo "  Truncating image file..."
truncate -s "$NEW_IMG_SIZE" "$IMAGE_FILE"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"