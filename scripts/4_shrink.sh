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
# Actually shrink the filesystem.
# The old script just moved the file — leaving 2GB of empty space in the image.
# This section shrinks the ext4 partition to its minimum size, then truncates
# the image file to match. Typically cuts 1.5-2GB off the output.
# ---------------------------------------------------------------------------
echo "Shrinking filesystem..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")

echo "  Running fsck before resize..."
e2fsck -f -y "${LOOP_DEV}p2"

echo "  Shrinking ext4 to minimum size..."
resize2fs -M "${LOOP_DEV}p2"

# Calculate the exact byte offset where p2 ends after shrinking
BLOCK_SIZE=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block size:/ {print $3}')
BLOCK_COUNT=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block count:/ {print $3}')
P2_START=$(parted -m "$IMAGE_FILE" unit B print | awk -F: '/^2:/ {gsub("B",""); print $2}')

# New total image size = start of p2 + size of shrunk p2 + small alignment buffer
NEW_SIZE=$(( P2_START + BLOCK_SIZE * BLOCK_COUNT + 1048576 ))
echo "  Truncating image to ${NEW_SIZE} bytes (~$(( NEW_SIZE / 1024 / 1024 )) MB)..."

# Update the partition table to reflect the new smaller p2 end
NEW_END=$(( P2_START + BLOCK_SIZE * BLOCK_COUNT ))
parted -s "$IMAGE_FILE" resizepart 2 ${NEW_END}B

losetup -d "$LOOP_DEV"
sync

# Truncate the image file itself to the calculated size
truncate -s $NEW_SIZE "$IMAGE_FILE"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh $OUTPUT_FILE | cut -f1)"