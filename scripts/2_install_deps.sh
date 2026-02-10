#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ----------------------------------------------------------------
# STEP 1: PREPARE MOUNTS (CRITICAL FOR SPEED)
# ----------------------------------------------------------------
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Mounting system directories..."
# We bind mount these to prevent the "posix_openpt" 15-minute timeout error
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

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# SPEED HACK: Prevent man-db from running (Saves huge amount of CPU)
echo "Man-DB: Disabling auto-update..."
mkdir -p /var/lib/man-db
touch /var/lib/man-db/auto-update

# Prevent services from starting during install
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "Running APT Update..."
apt-get update

echo "Installing Basic Tools..."
# 1. eatmydata: Disables disk sync (makes QEMU 10x faster)
# 2. network-manager: Gives you 'nmcli'
# 3. ca-certificates: Required for your Go app to make HTTPS requests
# 4. wpasupplicant: Required for WiFi connections via nmcli
# REMOVED: Docker (Not needed for your go.mod)
apt-get install -y eatmydata
eatmydata apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables

echo "Configuring Network Manager..."
systemctl enable NetworkManager

# Fix /etc/network/interfaces so it doesn't fight with NetworkManager
if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

echo "Configuring User 'martbul'..."
if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    # Removed 'docker' group since we aren't installing docker
    usermod -aG sudo martbul
fi

echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm /usr/sbin/policy-rc.d
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