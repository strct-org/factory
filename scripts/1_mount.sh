#!/bin/bash
set -e

IMAGE_FILE="../raspberrypi.img" 
MOUNT_POINT="mnt_root"

if [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: Cannot find $IMAGE_FILE"
    exit 1
fi

echo "Creating mount directory..."
mkdir -p $MOUNT_POINT

echo "Setting up loop device..."
LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")

echo "Image mapped to $LOOP_DEV"

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

echo "Image mounted at $MOUNT_POINT"