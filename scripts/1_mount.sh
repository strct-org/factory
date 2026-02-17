#!/bin/bash
set -euo pipefail

SOURCE_IMAGE="../orangepi.img"
WORK_IMAGE="../work_image.img"
MOUNT_POINT="mnt_root"

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "[ERROR] Cannot find $SOURCE_IMAGE"
    exit 1
fi

echo "Creating working copy of image..."
cp --reflink=auto "$SOURCE_IMAGE" "$WORK_IMAGE"

echo "Adding 2GB of space to image..."
truncate -s +2G "$WORK_IMAGE"

echo "Fixing GPT partition table (moving backup header to end)..."
sgdisk -e "$WORK_IMAGE"

echo "Setting up loop device..."
LOOP_DEV=$(losetup -fP --show "$WORK_IMAGE")
echo "Image mapped to $LOOP_DEV"

echo "Detecting Root partition..."
ROOT_PART_NUM=$(parted -m "$LOOP_DEV" unit B print | tail -n +3 | sort -t: -k4 -nr | head -n1 | cut -d: -f1)
ROOT_DEV="${LOOP_DEV}p${ROOT_PART_NUM}"

echo "Detected Root Partition: $ROOT_DEV (Partition $ROOT_PART_NUM)"

echo "Resizing partition $ROOT_PART_NUM to 100%..."
parted -s "$WORK_IMAGE" resizepart "$ROOT_PART_NUM" 100%
partprobe "$LOOP_DEV"

echo "Expanding filesystem..."
e2fsck -f -y "$ROOT_DEV" || true
resize2fs "$ROOT_DEV"

echo "Creating mount directory..."
mkdir -p "$MOUNT_POINT"

echo "Mounting Root partition..."
mount "$ROOT_DEV" "$MOUNT_POINT"

if [ -z "$(ls -A "$MOUNT_POINT/boot")" ]; then
    echo "Boot directory is empty. Checking for separate boot partition..."
    if [ "$ROOT_PART_NUM" -eq "2" ] && [ -b "${LOOP_DEV}p1" ]; then
         echo "Mounting p1 to /boot..."
         mount "${LOOP_DEV}p1" "$MOUNT_POINT/boot"
    fi
fi

echo "Binding system directories..."
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"

echo "Injecting QEMU for ARM64..."
cp /usr/bin/qemu-aarch64-static "$MOUNT_POINT/usr/bin/"

echo "Copying DNS resolver..."
rm -f "$MOUNT_POINT/etc/resolv.conf"
cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"

echo "[OK] Image mounted and expanded at $MOUNT_POINT"
