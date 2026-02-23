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
# ---------------------------------------------------------------------------
echo "Shrinking filesystem..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")

echo "  Running fsck before resize..."
e2fsck -f -y "${LOOP_DEV}p2"

echo "  Shrinking ext4 to minimum size..."
resize2fs -M "${LOOP_DEV}p2"

# Read the new filesystem dimensions after shrinking
BLOCK_SIZE=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block size:/{print $3}')
BLOCK_COUNT=$(tune2fs -l "${LOOP_DEV}p2" | awk '/^Block count:/{print $3}')
FS_BYTES=$(( BLOCK_SIZE * BLOCK_COUNT ))

echo "  Filesystem block size: $BLOCK_SIZE"
echo "  Filesystem block count: $BLOCK_COUNT"
echo "  Filesystem size: $(( FS_BYTES / 1024 / 1024 )) MB"

# Get sector size and P2 start from fdisk.
# On loop devices, fdisk -l shows the device as e.g. /dev/loop0p2 — we must
# match on the full device path, not just "p2" which can fail or mis-match.
SECTOR_SIZE=$(fdisk -l "$IMAGE_FILE" | awk '/^Sector size \(logical/{print $4}')
P2_START_SECTOR=$(fdisk -l "$IMAGE_FILE" | awk -v dev="${LOOP_DEV}p2" '$1 == dev {print $2}')

# Fallback: if loop device path doesn't match (some fdisk versions print the
# image path + partition suffix), try matching on the image file instead.
if [ -z "$P2_START_SECTOR" ]; then
    P2_START_SECTOR=$(fdisk -l "$IMAGE_FILE" | awk 'NR>1 && /p2/{print $2}' | head -1)
fi

if [ -z "$P2_START_SECTOR" ] || [ -z "$SECTOR_SIZE" ]; then
    echo "[ERROR] Could not determine sector size or P2 start sector from fdisk output."
    echo "        fdisk -l output:"
    fdisk -l "$IMAGE_FILE"
    losetup -d "$LOOP_DEV"
    exit 1
fi

echo "  Sector size:     $SECTOR_SIZE B"
echo "  P2 start sector: $P2_START_SECTOR"

# Calculate new end sector with a 2048-sector safety margin
FS_SECTORS=$(( ( FS_BYTES + SECTOR_SIZE - 1 ) / SECTOR_SIZE ))
P2_END_SECTOR=$(( P2_START_SECTOR + FS_SECTORS + 2048 ))
NEW_IMG_SECTORS=$(( P2_END_SECTOR + 1 ))
NEW_IMG_BYTES=$(( NEW_IMG_SECTORS * SECTOR_SIZE ))

echo "  New P2 end sector: $P2_END_SECTOR"
echo "  New image size:    $(( NEW_IMG_BYTES / 1024 / 1024 )) MB"

# Validate the end sector is within the image
MAX_SECTOR=$(fdisk -l "$IMAGE_FILE" | awk '/^Disk .*sectors/{print $7}')
if [ -n "$MAX_SECTOR" ] && [ "$P2_END_SECTOR" -gt "$MAX_SECTOR" ]; then
    echo "[ERROR] Calculated P2 end sector ($P2_END_SECTOR) exceeds image size ($MAX_SECTOR sectors)"
    echo "        This means the shrunken filesystem is larger than the original image — something is wrong."
    losetup -d "$LOOP_DEV"
    exit 1
fi

# Detach the loop device before modifying the partition table
losetup -d "$LOOP_DEV"
sync

# Rewrite partition 2 using fdisk heredoc — fully non-interactive.
echo "  Rewriting partition table with fdisk..."
fdisk "$IMAGE_FILE" <<FDISK_CMDS
d
2
n
p
2
$P2_START_SECTOR
$P2_END_SECTOR
w
FDISK_CMDS

echo "  Partition table rewritten."

# Truncate the image file itself to the new size
echo "  Truncating image file to $(( NEW_IMG_BYTES / 1024 / 1024 )) MB..."
truncate -s "$NEW_IMG_BYTES" "$IMAGE_FILE"

# Re-attach and run a final fsck to confirm everything is consistent
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
echo "  Final fsck..."
e2fsck -f -y "${LOOP_DEV}p2" || true
losetup -d "$LOOP_DEV"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"