#!/bin/bash
set -e

SOURCE_IMAGE="../orangepi.img"
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

# ── Armbian Orange Pi 3B (RK3566) partition layout ───────────────────────────
# p1 = FAT32 / Linux extended boot (~200MB) — kernel, DTBs, extlinux/
# p2 = ext4 root (rest)                     — full Debian rootfs
#
# The partition table is GPT. U-Boot / idbloader live in raw sectors 64–16383
# BEFORE p1 — do NOT touch those sectors.
#
# Why we avoid parted entirely:
#   GPT stores a backup header at the very last sector. After dd-appending
#   space, that header is no longer at the end. parted -s refuses to act on
#   ANY image with a misplaced GPT backup header and returns "Partition
#   doesn't exist." even after sgdisk -e, because parted revalidates and
#   finds the 2048-block alignment rounding leaves a tiny gap it considers
#   an error.
#
# Solution: do everything with sgdisk:
#   1. Read p2's start sector before touching anything
#   2. sgdisk -e   → move backup GPT header to true end of enlarged file
#   3. sgdisk -d 2 → delete p2 entry (start sector recorded above)
#   4. sgdisk -n   → recreate p2 from same start to end of disk (sector 0)
#   5. sgdisk -t   → restore Linux filesystem type (8300)
# ─────────────────────────────────────────────────────────────────────────────

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    echo "        build.yml should have downloaded and named it orangepi.img"
    exit 1
fi

echo "Creating working copy of image (original is preserved)..."
cp "$SOURCE_IMAGE" "$WORK_IMAGE"

echo "Adding 2GB of space to image..."
dd if=/dev/zero bs=1G count=2 >> "$WORK_IMAGE"

echo "Capturing p2 start sector before modifying GPT..."
P2_START=$(sgdisk -i 2 "$WORK_IMAGE" | awk '/First sector:/{print $3}')
if [ -z "$P2_START" ]; then
    echo "[ERROR] Could not read p2 start sector from image — is it a valid GPT image?"
    exit 1
fi
echo "  p2 starts at sector: $P2_START"

echo "Moving GPT backup header to new end of disk..."
sgdisk -e "$WORK_IMAGE"

echo "Deleting old p2 entry and recreating it to fill all remaining space..."
# -d 2         : delete partition 2
# -n 2:START:0 : new partition 2 from START to last sector (0 = end of disk)
# -t 2:8300    : type = Linux filesystem
sgdisk -d 2 "$WORK_IMAGE"
sgdisk -n "2:${P2_START}:0" -t "2:8300" "$WORK_IMAGE"

echo "Updated partition table:"
sgdisk -p "$WORK_IMAGE"

echo "Creating mount directory..."
mkdir -p $MOUNT_POINT

echo "Setting up loop device..."
LOOP_DEV=$(losetup -fP --show "$WORK_IMAGE")
echo "Image mapped to $LOOP_DEV"

echo "Expanding root filesystem to fill new partition..."
e2fsck -f -y "${LOOP_DEV}p2" || true
resize2fs "${LOOP_DEV}p2"

echo "Mounting root partition (p2)..."
mount "${LOOP_DEV}p2" $MOUNT_POINT

echo "Mounting boot partition (p1) at /boot..."
# Armbian places the boot partition at /boot (not /boot/firmware).
# The FAT partition contains: extlinux/, dtb/, vmlinuz, initrd.img, armbianEnv.txt
if [ -d "$MOUNT_POINT/boot" ]; then
    mount "${LOOP_DEV}p1" $MOUNT_POINT/boot
else
    echo "[ERROR] /boot directory does not exist on root partition"
    losetup -d "$LOOP_DEV"
    exit 1
fi

echo "Binding system directories for chroot..."
mount --bind /dev  $MOUNT_POINT/dev
mount --bind /proc $MOUNT_POINT/proc
mount --bind /sys  $MOUNT_POINT/sys

echo "Injecting QEMU for ARM64..."
cp /usr/bin/qemu-aarch64-static $MOUNT_POINT/usr/bin/

echo "Copying DNS resolver..."
cp /etc/resolv.conf $MOUNT_POINT/etc/resolv.conf

echo "[OK] Image mounted and expanded at $MOUNT_POINT"