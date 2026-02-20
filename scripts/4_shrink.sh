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
# Shrink the filesystem and image.
# parted -s still shows an interactive "are you sure?" prompt when shrinking
# a partition — even in script mode. We avoid parted entirely for the resize
# step and use fdisk instead, which is fully scriptable with no prompts.
# ---------------------------------------------------------------------------
echo "Shrinking filesystem..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")

echo "  Running fsck before resize..."
e2fsck -f -y "${LOOP_DEV}p2"

echo "  Shrinking ext4 to minimum size..."
resize2fs -M "${LOOP_DEV}p2"

# Read the new partition dimensions after shrinking
BLOCK_SIZE=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block size:/{print $3}')
BLOCK_COUNT=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block count:/{print $3}')
FS_BYTES=$(( BLOCK_SIZE * BLOCK_COUNT ))

# Get the sector size and p2 start sector from fdisk
SECTOR_SIZE=$(fdisk -l "$IMAGE_FILE" | awk '/^Sector size/{print $4}')
P2_START_SECTOR=$(fdisk -l "$IMAGE_FILE" | awk '/p2/{print $2}')

# Calculate new p2 end sector (round up to include all fs blocks)
P2_END_SECTOR=$(( P2_START_SECTOR + (FS_BYTES / SECTOR_SIZE) + 2048 ))
NEW_IMG_SECTORS=$(( P2_END_SECTOR + 1 ))
NEW_IMG_BYTES=$(( NEW_IMG_SECTORS * SECTOR_SIZE ))

echo "  Sector size:      $SECTOR_SIZE B"
echo "  P2 start sector:  $P2_START_SECTOR"
echo "  New P2 end sector: $P2_END_SECTOR"
echo "  New image size:   $(( NEW_IMG_BYTES / 1024 / 1024 )) MB"

# Detach the loop device before modifying the partition table
losetup -d "$LOOP_DEV"
sync

# Rewrite partition 2 using fdisk in batch/heredoc mode — no prompts at all.
# d = delete partition, n = new partition, p = primary, keep same start,
# set new end sector, w = write.
echo "  Rewriting partition table with fdisk (no prompts)..."
fdisk "$IMAGE_FILE" << FDISK_CMDS
d
2
n
p
2
$P2_START_SECTOR
$P2_END_SECTOR
w
FDISK_CMDS

# Truncate the image file itself to the new calculated size
echo "  Truncating image file to $(( NEW_IMG_BYTES / 1024 / 1024 )) MB..."
truncate -s "$NEW_IMG_BYTES" "$IMAGE_FILE"

# Final fsck to make sure everything is consistent after partition table rewrite
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
echo "  Final fsck..."
e2fsck -f -y "${LOOP_DEV}p2" || true
losetup -d "$LOOP_DEV"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"