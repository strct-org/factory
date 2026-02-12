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
APT_FLAGS="-o Acquire::IndexTargets::deb::cnf-Metadata=false -o APT::Sandbox::User=root -o Acquire::Languages=none -o Acquire::http::No-Cache=true"

echo "Cleaning old lists..."
rm -rf /var/lib/apt/lists/*

echo "Running APT Update (Fast Mode)..."
apt-get update \$APT_FLAGS

echo "Installing Basic Tools..."
apt-get install -y \$APT_FLAGS eatmydata

echo "Installing NetworkManager & Utils..."
# Added 'iw' and 'rfkill' for debugging and radio control
eatmydata apt-get install -y --no-install-recommends \$APT_FLAGS \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables \
    dnsutils \
    rfkill \
    iw

# Verify Installation
if command -v nmcli &> /dev/null; then
    echo "[OK] nmcli successfully installed."
else
    echo "[ERROR] nmcli failed to install."
    exit 1
fi

# ---------------------------------------------------------
# CRITICAL FIX: CONFLICT RESOLUTION
# ---------------------------------------------------------
echo "Configuring Network Manager as default..."

# 1. Clean existing Netplan configs (which usually point to networkd)
rm -f /etc/netplan/*.yaml

# 2. Create NetworkManager-only Netplan config
cat <<NETPLAN > /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
NETPLAN

chmod 600 /etc/netplan/01-network-manager-all.yaml

# 3. Disable systemd-networkd (Stops it from fighting for the IP)
systemctl disable systemd-networkd
systemctl mask systemd-networkd
systemctl stop systemd-networkd

# 4. Disable standalone wpa_supplicant (NetworkManager spawns its own)
# If this runs standalone, it locks the wifi card (Error -52)
systemctl disable wpa_supplicant
systemctl mask wpa_supplicant

# 5. Enable NetworkManager
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

echo "[OK] Build Complete. Networking conflicts resolved."