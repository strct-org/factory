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

echo "  Filesystem block size:  $BLOCK_SIZE"
echo "  Filesystem block count: $BLOCK_COUNT"
echo "  Filesystem size:        $(( FS_BYTES / 1024 / 1024 )) MB"

# Detach loop device before reading partition table from the image file directly.
# fdisk on the image file prints rows like:
#   ../work_image.img2   2105344  11337727  9232384  4.4G 83 Linux
# The Boot column may or may not be present, so we cannot rely on fixed column
# positions. Instead we match any row where field 1 ends in "2" (partition 2)
# and grab the first purely numeric field after it as the start sector.
losetup -d "$LOOP_DEV"
sync

FDISK_OUT=$(fdisk -l "$IMAGE_FILE")
echo "  fdisk output:"
echo "$FDISK_OUT"

SECTOR_SIZE=$(echo "$FDISK_OUT" | awk '/^Sector size \(logical/{print $4}')

# Parse P2 start sector robustly:
# - Match the line whose first field ends in "2"
# - Strip a possible "*" Boot flag (field 2 may be "*")
# - The start sector is then the first all-digit field >= 2048
P2_START_SECTOR=$(echo "$FDISK_OUT" | awk '
    $1 ~ /2$/ {
        for (i=2; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $i+0 >= 2048) {
                print $i
                exit
            }
        }
    }
')

if [ -z "$P2_START_SECTOR" ] || [ -z "$SECTOR_SIZE" ]; then
    echo "[ERROR] Could not parse sector size or P2 start sector."
    echo "        SECTOR_SIZE='$SECTOR_SIZE'  P2_START_SECTOR='$P2_START_SECTOR'"
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

# Truncate the image file to the new size
echo "  Truncating image file to $(( NEW_IMG_BYTES / 1024 / 1024 )) MB..."
truncate -s "$NEW_IMG_BYTES" "$IMAGE_FILE"

# Re-attach and run a final fsck to confirm consistency
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
echo "  Final fsck..."
e2fsck -f -y "${LOOP_DEV}p2" || true
losetup -d "$LOOP_DEV"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"