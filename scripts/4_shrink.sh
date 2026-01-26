#!/bin/bash
set -e

# INPUT: The large working image we created in step 1
IMAGE_FILE="../work_image.img"
# OUTPUT: The final compressed release file
OUTPUT_FILE="../strct-release-v1.img"
MOUNT_POINT="mnt_root"

echo "Unmounting image..."

# Lazy unmount to avoid 'busy' errors
umount -lf $MOUNT_POINT/boot || true
umount -lf $MOUNT_POINT/dev || true
umount -lf $MOUNT_POINT/proc || true
umount -lf $MOUNT_POINT/sys || true
umount -lf $MOUNT_POINT || true

# Detach loop device
losetup -D

echo "Shrinking image using PiShrink..."

if [ ! -f "pishrink.sh" ]; then
    wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
    chmod +x pishrink.sh
fi

# Run PiShrink
# Arguments: [Input File] [Output File]
./pishrink.sh "$IMAGE_FILE" "$OUTPUT_FILE"

# Delete the large working file to save space
rm "$IMAGE_FILE"

echo "[OK] DONE! Final image is located at: $OUTPUT_FILE"