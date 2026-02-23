#!/bin/bash
set -e

SOURCE_IMAGE="../orangepi.img"
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    echo "        build.yml should have downloaded and named it orangepi.img"
    exit 1
fi

echo "Creating working copy of image (original is preserved)..."
cp "$SOURCE_IMAGE" "$WORK_IMAGE"

echo "Adding 2GB of space to image..."
dd if=/dev/zero bs=1G count=2 >> "$WORK_IMAGE"

echo "Resizing partition table..."
parted -s "$WORK_IMAGE" resizepart 2 100%

echo "Creating mount directory..."
mkdir -p $MOUNT_POINT

echo "Setting up loop device..."
LOOP_DEV=$(losetup -fP --show "$WORK_IMAGE")
echo "Image mapped to $LOOP_DEV"

echo "Expanding filesystem to fill partition..."
e2fsck -f -y "${LOOP_DEV}p2" || true
resize2fs "${LOOP_DEV}p2"

echo "Mounting root partition (p2)..."
mount "${LOOP_DEV}p2" $MOUNT_POINT

# Orange Pi Debian images use /boot — not /boot/firmware like Raspberry Pi OS.
# We check for cmdline.txt to confirm which layout is present.
if [ -f "$MOUNT_POINT/boot/firmware/cmdline.txt" ]; then
    echo "Detected /boot/firmware layout. Mounting boot there..."
    mount "${LOOP_DEV}p1" $MOUNT_POINT/boot/firmware
elif [ -d "$MOUNT_POINT/boot" ]; then
    echo "Detected /boot layout. Mounting boot there..."
    mount "${LOOP_DEV}p1" $MOUNT_POINT/boot
else
    echo "[ERROR] Cannot determine boot mount point — neither /boot nor /boot/firmware exist"
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