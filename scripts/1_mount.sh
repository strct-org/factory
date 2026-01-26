#!/bin/bash
set -e

# Input: The base downloaded image
SOURCE_IMAGE="../raspberrypi.img"
# Work File: We create this temporary file to modify
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    exit 1
fi

# 1. Create a fresh working copy
echo "Creating working copy of image..."
cp "$SOURCE_IMAGE" "$WORK_IMAGE"

# 2. EXPAND THE IMAGE (Fixes 'No space left on device')
echo "Adding 2GB of space to image..."
dd if=/dev/zero bs=1G count=2 >> "$WORK_IMAGE"

echo "Resizing partition table..."
# Resize partition 2 (Root) to fill the new space
parted -s "$WORK_IMAGE" resizepart 2 100%

# 3. Mount and Resize Filesystem
echo "Creating mount directory..."
mkdir -p $MOUNT_POINT

echo "Setting up loop device..."
LOOP_DEV=$(losetup -fP --show "$WORK_IMAGE")
echo "Image mapped to $LOOP_DEV"

echo "Expanding filesystem to fill partition..."
# Check and resize the ext4 filesystem
e2fsck -f -y "${LOOP_DEV}p2" || true
resize2fs "${LOOP_DEV}p2"

echo "Mounting Root partition (p2)..."
mount "${LOOP_DEV}p2" $MOUNT_POINT

echo "Mounting Boot partition (p1)..."
mount "${LOOP_DEV}p1" $MOUNT_POINT/boot

echo "Binding system directories..."
mount --bind /dev $MOUNT_POINT/dev
mount --bind /proc $MOUNT_POINT/proc
mount --bind /sys $MOUNT_POINT/sys

echo "Injecting QEMU for ARM64..."
cp /usr/bin/qemu-aarch64-static $MOUNT_POINT/usr/bin/

echo "Copying DNS resolver..."
cp /etc/resolv.conf $MOUNT_POINT/etc/resolv.conf

echo "[OK] Image mounted and expanded at $MOUNT_POINT"