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
# We read p2's start sector from the ORIGINAL image BEFORE appending space,
# because sgdisk -i can't parse a GPT whose backup header is displaced.
# After dd we: fix the header with sgdisk -e, delete p2, recreate it from
# the same start to end of disk, then resize the ext4 fs inside it.
# ─────────────────────────────────────────────────────────────────────────────

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    echo "        build.yml should have downloaded and named it orangepi.img"
    exit 1
fi

echo "Reading p2 start sector from original image (before any modification)..."
P2_START=$(sgdisk -i 2 "$SOURCE_IMAGE" | awk '/First sector:/{print $3}')
if [ -z "$P2_START" ]; then
    echo "[ERROR] Could not read p2 start sector — is $SOURCE_IMAGE a valid GPT image?"
    sgdisk -p "$SOURCE_IMAGE" || true
    exit 1
fi
echo "  p2 starts at sector: $P2_START"

echo "Creating working copy of image (original is preserved)..."
cp "$SOURCE_IMAGE" "$WORK_IMAGE"

echo "Adding 2GB of space to image..."
dd if=/dev/zero bs=1G count=2 >> "$WORK_IMAGE"

echo "Moving GPT backup header to new end of disk..."
sgdisk -e "$WORK_IMAGE"

echo "Deleting old p2 entry and recreating it to fill all remaining space..."
# -d 2         : delete partition 2 table entry (data on disk untouched)
# -n 2:START:0 : new p2 from original start to last sector (0 = end of disk)
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