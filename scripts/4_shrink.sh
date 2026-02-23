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
# Strategy: shrink the ext4 filesystem only, then truncate the image file
# to just past the end of partition 2 as defined by the ORIGINAL partition
# table. We never rewrite the partition table — doing so risks corrupting
# the MBR or the U-Boot payload stored in raw sectors 8-8191 before p1.
# ---------------------------------------------------------------------------

echo "Attaching image..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
echo "  Loop device: $LOOP_DEV"

echo "  Running fsck before resize..."
e2fsck -f -y "${LOOP_DEV}p2"

echo "  Shrinking ext4 filesystem to minimum size..."
resize2fs -M "${LOOP_DEV}p2"

echo "  Running fsck after resize..."
e2fsck -f -y "${LOOP_DEV}p2"

# ---------------------------------------------------------------------------
# Calculate truncation point.
# We truncate the IMAGE to just past the END of p2 as the partition table
# already defines it — we are NOT moving the partition boundary, just
# removing the empty space we added in 1_mount.sh.
#
# Get p2 end sector from fdisk output on the IMAGE FILE (not loop device).
# fdisk prints rows like:
#   ../work_image.img2   2105344  11337727  9232384  4.4G  83  Linux
# We match any row whose first field ends in "2" and grab the end sector,
# which is the second numeric field >= 2048 (start is first, end is second).
# ---------------------------------------------------------------------------
losetup -d "$LOOP_DEV"
sync

FDISK_OUT=$(fdisk -l "$IMAGE_FILE")
echo ""
echo "  Partition table:"
echo "$FDISK_OUT"
echo ""

SECTOR_SIZE=$(echo "$FDISK_OUT" | awk '/^Sector size \(logical/{print $4}')

P2_END_SECTOR=$(echo "$FDISK_OUT" | awk '
    $1 ~ /2$/ {
        count = 0
        for (i=2; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $i+0 >= 2048) {
                count++
                if (count == 2) {   # first numeric >= 2048 is Start, second is End
                    print $i
                    exit
                }
            }
        }
    }
')

if [ -z "$P2_END_SECTOR" ] || [ -z "$SECTOR_SIZE" ]; then
    echo "[ERROR] Could not parse P2 end sector or sector size."
    echo "        SECTOR_SIZE='$SECTOR_SIZE'  P2_END_SECTOR='$P2_END_SECTOR'"
    exit 1
fi

# Truncate to just past the last sector of p2, with a small 1MB safety buffer
TRUNCATE_BYTES=$(( ( P2_END_SECTOR + 1 ) * SECTOR_SIZE + 1048576 ))

echo "  Sector size:    $SECTOR_SIZE B"
echo "  P2 end sector:  $P2_END_SECTOR"
echo "  Truncating to:  $(( TRUNCATE_BYTES / 1024 / 1024 )) MB"

truncate -s "$TRUNCATE_BYTES" "$IMAGE_FILE"

# Final fsck on the truncated image
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
echo "  Final fsck..."
e2fsck -f -y "${LOOP_DEV}p2" || true
losetup -d "$LOOP_DEV"

echo "Finalizing..."
mv "$IMAGE_FILE" "$OUTPUT_FILE"

echo "[OK] DONE! Final image: $OUTPUT_FILE"
echo "     Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"