#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# Safety check: Ensure the mount point exists
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Entering Chroot to install dependencies..."

# We use EOF (unquoted) to allow variable expansion if needed, 
# but we escape variables intended for the inner script with backslashes.
cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------
# SPEED OPTIMIZATIONS
# ----------------------------------------------------------------

# 1. Prevent services from trying to start inside Chroot
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# 2. Disable documentation/man-pages
# FIXED: Correct syntax for apt.conf.d
cat <<NODOC > /etc/apt/apt.conf.d/01nodoc
DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };
APT::Install-Recommends "0";
APT::Install-Suggests "0";
Dir::Ignore-Files-Silently:: "(.save|.distupgrade)$";
DPkg::Path-Exclude "/usr/share/doc/*";
DPkg::Path-Exclude "/usr/share/man/*";
DPkg::Path-Exclude "/usr/share/groff/*";
DPkg::Path-Exclude "/usr/share/info/*";
DPkg::Path-Exclude "/usr/share/lintian/*";
DPkg::Path-Exclude "/usr/share/linda/*";
NODOC

# ----------------------------------------------------------------
# INSTALLATION
# ----------------------------------------------------------------

echo "Running APT update..."
apt-get update

echo "Installing Basic Tools..."
# Install 'eatmydata' first. This disables fsync() and makes QEMU disk ops 10x faster.
apt-get install -y --no-install-recommends eatmydata curl wget ca-certificates

echo "Installing Network Manager (MINIMAL)..."
# 1. Use 'eatmydata' to speed up unpacking
# 2. Use '--no-install-recommends' to prevent installing X11/Bloat
# 3. Explicitly include wpasupplicant for WiFi support
eatmydata apt-get install -y --no-install-recommends network-manager wpasupplicant

# Verify nmcli
if command -v nmcli &> /dev/null; then
    echo "[OK] nmcli successfully installed."
else
    echo "[ERROR] nmcli failed to install."
    exit 1
fi

# ----------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------

echo "Configuring Network Manager..."
systemctl enable NetworkManager

if [ -f /etc/network/interfaces ]; then
    echo "Backing up /etc/network/interfaces..."
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

if ! command -v docker &> /dev/null; then
    echo "Downloading Docker..."
    DOCKER_VERSION="24.0.7"
    
    # CRITICAL FIX: Use eatmydata on curl
    eatmydata curl -sSL "https://download.docker.com/linux/static/stable/aarch64/docker-\${DOCKER_VERSION}.tgz" -o docker.tgz

    echo "Extracting Docker..."
    # CRITICAL FIX: Use eatmydata on tar. 
    # Without this, QEMU translates every file write sync, causing the 30min delay.
    eatmydata tar xzf docker.tgz
    
    cp docker/* /usr/bin/
    rm -rf docker docker.tgz

    groupadd -f docker

    echo "Creating Docker Systemd Service..."
    cat <<SERVICE > /etc/systemd/system/docker.service
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl enable docker
fi

# ----------------------------------------------------------------
# USER CONFIGURATION
# ----------------------------------------------------------------
echo "Configuring User 'martbul'..."

if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
fi

echo "martbul:1234
root:1234" | chpasswd

usermod -aG sudo,docker martbul

# ----------------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------------

# Restore system to normal state
rm /usr/sbin/policy-rc.d
rm /etc/apt/apt.conf.d/01nodoc

echo "Cleaning up APT cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Script Complete."