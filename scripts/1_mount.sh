#!/bin/bash
set -e

SOURCE_IMAGE="../orangepi.img"
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

# ── Armbian Orange Pi 3B (RK3566) partition layout ───────────────────────────
# p1 = FAT32 boot partition  (~200MB) — contains kernel, DTBs, extlinux/
# p2 = ext4 root partition   (rest)   — the full Debian rootfs
#
# U-Boot / idbloader / ATF are written into raw sectors 64–16383 BEFORE p1.
# That raw area must never be touched (no dd, no parted resize of p1 start).
# We only ever expand p2 (the root) and resize its filesystem.
#
# Boot configuration lives at:
#   /boot/extlinux/extlinux.conf   (bootloader reads this via extlinux)
#   /boot/armbianEnv.txt           (Armbian overlay / DTB selection)
# There is no cmdline.txt — that is a Raspberry Pi concept.
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

echo "Resizing partition table (extending p2 only)..."
# We only resize p2. p1 (boot FAT) is left exactly as-is so that the raw
# U-Boot sectors before it and the FAT boot files remain untouched.
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