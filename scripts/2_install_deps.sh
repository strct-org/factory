#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ----------------------------------------------------------------
# STEP 1: PREPARE MOUNTS
# ----------------------------------------------------------------
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Mounting system directories..."
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

# ==============================================================================
# THE 25-MINUTE FIX
# ==============================================================================
# This configuration file stops APT from downloading the Metadata that hangs QEMU.
# 1. cnf-Metadata "false" -> Stops the specific file you are stuck on.
# 2. Languages "none" -> Stops downloading translation files.
# 3. Sandbox::User "root" -> Prevents freezing when switching permissions.
cat <<APTCONF > /etc/apt/apt.conf.d/99-qemu-force-speed
Acquire::IndexTargets::deb::cnf-Metadata "false";
Acquire::Languages "none";
APT::Sandbox::User "root";
Acquire::http::No-Cache "true";
Acquire::http::Pipeline-Depth "0";
APTCONF
# ==============================================================================

# Disable man-db updates (CPU Hog)
echo "Man-DB: Disabling auto-update..."
mkdir -p /var/lib/man-db
touch /var/lib/man-db/auto-update

# Prevent services from starting
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "Cleaning old lists..."
rm -rf /var/lib/apt/lists/*

echo "Running APT Update (Fast Mode)..."
# We use eatmydata here too because updating lists involves writing many files
apt-get update || echo "Update had warnings, but continuing..."

echo "Installing Basic Tools..."
# Install eatmydata first
apt-get install -y eatmydata

echo "Installing Dependencies..."
# 1. network-manager: For nmcli
# 2. ca-certificates: For your Go app HTTPS
# 3. iptables: Usually needed by network agents
eatmydata apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables \
    dnsutils

echo "Configuring Network Manager..."
systemctl enable NetworkManager

# Fix /etc/network/interfaces
if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

echo "Configuring User..."
if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo martbul
fi

echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm /usr/sbin/policy-rc.d
rm /etc/apt/apt.conf.d/99-qemu-force-speed
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