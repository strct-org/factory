#!/bin/bash
set -e

IMAGE_FILE="../work_image.img"
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Syncing filesystem..."
sync

echo "Unmounting image partitions..."
# Armbian mounts boot at /boot (not /boot/firmware)
umount -lf "$MOUNT_POINT/boot"  2>/dev/null || true
umount -lf "$MOUNT_POINT/dev"   2>/dev/null || true
umount -lf "$MOUNT_POINT/proc"  2>/dev/null || true
umount -lf "$MOUNT_POINT/sys"   2>/dev/null || true
umount -lf "$MOUNT_POINT"       2>/dev/null || true
sync

echo "Detaching all loop devices..."
losetup -D

# ---------------------------------------------------------------------------
# Strategy: shrink the ext4 root filesystem (p2), then truncate the image
# file to just past the end of p2 as defined by the partition table.
#
# We never rewrite or move partition boundaries — doing so would destroy the
# raw U-Boot / idbloader payload stored in sectors 64–16383 before p1, which
# is what actually makes the board boot. We only remove the empty space we
# appended in 1_mount.sh.
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

losetup -d "$LOOP_DEV"
sync

# ---------------------------------------------------------------------------
# Calculate truncation point from the p2 partition boundary.
#
# fdisk output for the 2-partition Armbian layout looks like:
#   Device          Boot   Start      End  Sectors  Size  Id  Type
#   work_image.img1         8192   409599   401408  196M   c  W95 FAT32 (LBA)
#   work_image.img2       409600  xxxxxxx  xxxxxxx  ...   83  Linux
#
# We match the row whose device field ends in "2" and extract its End sector.
# ---------------------------------------------------------------------------
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
                if (count == 2) {   # Start is first large int, End is second
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

# Truncate to just past the last sector of p2, plus a small 1MB safety buffer
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