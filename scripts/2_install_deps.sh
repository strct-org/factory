#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# Safety check: Ensure the mount point exists
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------
# 1. OPTIMIZATION & CONFIGURATION
# ----------------------------------------------------------------

# Prevent services from starting
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Configure APT for Speed and Reliability
# - Disable Docs/Man pages
# - Disable 'Command-Not-Found' metadata (Fixes the 15min hang)
# - Disable Translations
# - Use Root sandbox to prevent permission freezes
cat <<NODOC > /etc/apt/apt.conf.d/99optimizations
DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };
APT::Install-Recommends "0";
APT::Install-Suggests "0";
APT::Sandbox::User "root";
Acquire::http::Pipeline-Depth "0";
Acquire::http::No-Cache "true";
Acquire::BrokenProxy "true";
Acquire::Languages "none";
Acquire::IndexTargets::deb::cnf-Metadata "false";
Dir::Ignore-Files-Silently:: "(.save|.distupgrade)$";
DPkg::Path-Exclude "/usr/share/doc/*";
DPkg::Path-Exclude "/usr/share/man/*";
DPkg::Path-Exclude "/usr/share/groff/*";
DPkg::Path-Exclude "/usr/share/info/*";
DPkg::Path-Exclude "/usr/share/lintian/*";
DPkg::Path-Exclude "/usr/share/linda/*";
NODOC

# ----------------------------------------------------------------
# 2. INSTALLATION
# ----------------------------------------------------------------

echo "Cleaning stale lists..."
rm -rf /var/lib/apt/lists/*

echo "Running APT update..."
apt-get update

echo "Installing Basic Tools..."
# Install 'eatmydata' first. It is CRITICAL for speed in QEMU.
apt-get install -y --no-install-recommends eatmydata curl wget ca-certificates

echo "Installing Network Manager & Docker..."
# COMBINED INSTALLATION FOR SPEED
# 1. network-manager + wpasupplicant (for WiFi)
# 2. docker.io (Installs via apt in 30s vs 20mins for manual tar extraction)
eatmydata apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    docker.io

# Verify Installations
if command -v nmcli &> /dev/null && command -v docker &> /dev/null; then
    echo "[OK] nmcli and docker installed successfully."
else
    echo "[ERROR] Installation failed."
    exit 1
fi

# ----------------------------------------------------------------
# 3. CONFIGURATION
# ----------------------------------------------------------------

echo "Configuring Network Manager..."
systemctl enable NetworkManager

# Fix /etc/network/interfaces to not conflict with NM
if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

echo "Configuring Docker..."
# Docker.io from apt already creates the service, just enable it
systemctl enable docker
# Add the group just in case
groupadd -f docker

# ----------------------------------------------------------------
# 4. USER CONFIGURATION
# ----------------------------------------------------------------
echo "Configuring User 'martbul'..."

if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
fi

echo "martbul:1234
root:1234" | chpasswd

usermod -aG sudo,docker martbul

# ----------------------------------------------------------------
# 5. CLEANUP
# ----------------------------------------------------------------

echo "Cleaning up..."
# Restore system to normal state
rm /usr/sbin/policy-rc.d
rm /etc/apt/apt.conf.d/99optimizations

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Script Complete."