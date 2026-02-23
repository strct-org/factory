#!/bin/bash
set -e

SOURCE_IMAGE="../orangepi.img"
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

# ── Armbian Orange Pi 3B (RK3566) partition layout ───────────────────────────
# p1 = FAT32 / Linux extended boot (~200MB) — kernel, DTBs, extlinux/
# p2 = ext4 root (rest)                     — full Debian rootfs
#
# The partition table is GPT. U-Boot / idbloader are in raw sectors 64–16383
# BEFORE p1, inside the protective MBR area. Do NOT touch those sectors.
#
# GPT stores a backup header at the very LAST sector of the disk. When we
# append 2GB with dd, that backup header is no longer at the end — parted
# sees the mismatch and refuses to resize until it is fixed. We use
# sgdisk --move-second-header (-e) to relocate the backup header to the new
# end of the disk before running parted.
# ─────────────────────────────────────────────────────────────────────────────

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    echo "        build.yml should have downloaded and named it orangepi.img"
    exit 1
fi

echo "Installing sgdisk (required for GPT header repair)..."
apt-get install -y gdisk > /dev/null 2>&1

echo "Creating working copy of image (original is preserved)..."
cp "$SOURCE_IMAGE" "$WORK_IMAGE"

echo "Adding 2GB of space to image..."
dd if=/dev/zero bs=1G count=2 >> "$WORK_IMAGE"

echo "Repairing GPT backup header (moved to new end of disk after dd)..."
# sgdisk -e / --move-second-header rewrites the backup GPT header and
# partition table to the last sectors of the now-larger image file.
# Without this step parted exits with "Partition doesn't exist."
sgdisk -e "$WORK_IMAGE"

echo "Resizing root partition (p2) to fill new space..."
parted -s "$WORK_IMAGE" resizepart 2 100%

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