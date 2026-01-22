#!/bin/bash
set -e

IMAGE_FILE="orangepi.img" # You will rename your downloaded image to this
MOUNT_POINT="mnt_root"

echo "Creating mount directory..."
mkdir -p $MOUNT_POINT

echo "Setting up loop device..."
# -P scans for partitions (p1, p2)
LOOP_DEV=$(sudo losetup -fP --show "$IMAGE_FILE")

echo "Image mapped to $LOOP_DEV"

# Mount the Root filesystem (usually partition 2 on Orange Pi images)
# Note: Check with 'fdisk -l orangepi.img' if p2 is indeed Linux
echo "Mounting Root partition..."
sudo mount "${LOOP_DEV}p2" $MOUNT_POINT

echo "Mounting Boot partition (optional, usually p1)..."
sudo mount "${LOOP_DEV}p1" $MOUNT_POINT/boot

echo "Binding system directories for chroot..."
sudo mount --bind /dev $MOUNT_POINT/dev
sudo mount --bind /proc $MOUNT_POINT/proc
sudo mount --bind /sys $MOUNT_POINT/sys

# CRITICAL: Copy QEMU binary so we can run ARM commands on x86
echo "Injecting QEMU for ARM64..."
sudo cp /usr/bin/qemu-aarch64-static $MOUNT_POINT/usr/bin/

echo "Image mounted at $MOUNT_POINT"
echo "Exporting LOOP_DEV=$LOOP_DEV"