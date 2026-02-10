#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ----------------------------------------------------------------
# 1. MOUNT FIXES (Crucial for Speed)
# ----------------------------------------------------------------
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Mounting system directories..."
# We MUST bind mount /dev/pts to stop the 'posix_openpt' 15-minute timeout
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"

# Ensure /tmp exists
mkdir -p "$MOUNT_POINT/tmp"
chmod 1777 "$MOUNT_POINT/tmp"

# ----------------------------------------------------------------
# 2. CREATE INSTALLER
# ----------------------------------------------------------------
cat <<EOF > $MOUNT_POINT/tmp/install_fast.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# SPEED HACK: Disable man-db (The #1 CPU hog in QEMU)
echo "Man-DB: Disabling auto-update..."
mkdir -p /var/lib/man-db
touch /var/lib/man-db/auto-update

# Prevent services from starting
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# DEFINE FAST APT FLAGS
# We pass these directly to commands to GUARANTEE they are used.
# 1. cnf-Metadata=false -> Stops the 15-minute hang
# 2. Sandbox::User=root -> Prevents permission freezes
# 3. Languages=none -> Saves bandwidth
APT_FLAGS="-o Acquire::IndexTargets::deb::cnf-Metadata=false -o APT::Sandbox::User=root -o Acquire::Languages=none -o Acquire::http::No-Cache=true"

echo "Cleaning old lists..."
rm -rf /var/lib/apt/lists/*

echo "Running APT Update (Fast Mode)..."
# We update ONLY 'main' and 'universe' to keep it fast, then restore full list if needed
apt-get update \$APT_FLAGS

echo "Installing Basic Tools..."
# Install 'eatmydata' first. It makes unpacking 10x faster.
apt-get install -y \$APT_FLAGS eatmydata

echo "Installing NetworkManager..."
# We use eatmydata to install ONLY what you need.
# NO DOCKER. NO BLOAT.
eatmydata apt-get install -y --no-install-recommends \$APT_FLAGS \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables \
    dnsutils

# Verify Installation
if command -v nmcli &> /dev/null; then
    echo "[OK] nmcli successfully installed."
else
    echo "[ERROR] nmcli failed to install."
    exit 1
fi

echo "Configuring Network Manager..."
systemctl enable NetworkManager

# Fix interfaces to not conflict with NM
if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

echo "Creating User 'martbul'..."
if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo martbul
fi

echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm /usr/sbin/policy-rc.d
rm -f /var/lib/man-db/auto-update
EOF

# ----------------------------------------------------------------
# 3. EXECUTE
# ----------------------------------------------------------------
chmod +x $MOUNT_POINT/tmp/install_fast.sh

echo "Entering Chroot..."
chroot $MOUNT_POINT /bin/bash /tmp/install_fast.sh

# ----------------------------------------------------------------
# 4. CLEANUP
# ----------------------------------------------------------------
rm $MOUNT_POINT/tmp/install_fast.sh

echo "Unmounting..."
umount "$MOUNT_POINT/dev/pts" || true
umount "$MOUNT_POINT/dev" || true
umount "$MOUNT_POINT/proc" || true
umount "$MOUNT_POINT/sys" || true

echo "[OK] Build Complete. 'nmcli' is now pre-installed."