#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ----------------------------------------------------------------
# STEP 1: PREPARE MOUNTS (CRITICAL FIX)
# ----------------------------------------------------------------
# You must bind-mount these for APT to work fast in QEMU
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Mounting system directories..."
# We assume the root partition is already mounted to $MOUNT_POINT
# We add these specifically to fix the 'posix_openpt' 30-min lag:
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"

# Ensure /tmp exists inside
mkdir -p "$MOUNT_POINT/tmp"
chmod 1777 "$MOUNT_POINT/tmp"

# ----------------------------------------------------------------
# STEP 2: CREATE THE INSTALLER SCRIPT
# ----------------------------------------------------------------
# This is the "Raspberry Pi Style" simple script, with QEMU speed hacks injected.

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# SPEED HACK 1: Disable man-db database updates (The #1 CPU hog in QEMU)
echo "Man-DB: Disabling auto-update..."
if [ -d /var/lib/man-db ]; then
    touch /var/lib/man-db/auto-update
fi
# Prevent services from starting
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "--------------------------------------"
echo "PHASE 1: Update & Install Helpers"
echo "--------------------------------------"
# We need to update to get the package lists
apt-get update

# Install 'eatmydata' first. 
# This tool disables disk sync, making installation 10x faster in QEMU.
apt-get install -y eatmydata

echo "--------------------------------------"
echo "PHASE 2: Install Docker & NetworkManager"
echo "--------------------------------------"

# We use 'eatmydata' to wrap the command. 
# This makes it behave like the Raspberry Pi script but safely bypasses QEMU I/O lag.
eatmydata apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    docker.io 

# Verify installs
if command -v nmcli >/dev/null && command -v docker >/dev/null; then
    echo "[OK] Docker and NetworkManager installed."
else
    echo "[ERROR] Install failed."
    exit 1
fi

echo "--------------------------------------"
echo "PHASE 3: Configuration"
echo "--------------------------------------"

# Enable Services
systemctl enable NetworkManager
systemctl enable docker

# Create User
if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo,docker martbul
    echo "[OK] User martbul created."
fi

# Cleanup
echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm /usr/sbin/policy-rc.d
# Re-enable man-db for the final system
rm -f /var/lib/man-db/auto-update

EOF

# ----------------------------------------------------------------
# STEP 3: EXECUTE
# ----------------------------------------------------------------

chmod +x $MOUNT_POINT/tmp/install_inside.sh

echo "Entering Chroot..."
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh

# ----------------------------------------------------------------
# STEP 4: CLEANUP MOUNTS
# ----------------------------------------------------------------
rm $MOUNT_POINT/tmp/install_inside.sh

echo "Unmounting system directories..."
umount "$MOUNT_POINT/dev/pts" || true
umount "$MOUNT_POINT/dev" || true
umount "$MOUNT_POINT/proc" || true
umount "$MOUNT_POINT/sys" || true

echo "[OK] Build Complete."