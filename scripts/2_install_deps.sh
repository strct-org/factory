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
# SPEED OPTIMIZATIONS (Keep these!)
# ----------------------------------------------------------------

# 1. Prevent services from trying to start inside Chroot
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# 2. Disable documentation/man-pages (Saves ~50% of install time)
# FIXED: Added correct syntax (DPkg::Path-Exclude, Quotes, and Semicolons)
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
# Only nukes lists if standard update fails (Speed improvement)
apt-get update || (rm -rf /var/lib/apt/lists/* && apt-get update)

echo "Installing Basic Tools..."
# Install these minimal to save space/time
apt-get install -y --no-install-recommends curl wget iptables ca-certificates

echo "Installing Network Manager (FULL)..."
# We deliberately allow 'Recommends' here for NetworkManager to ensure 
# nmcli, wpasupplicant (wifi), and modemmanager are included.
# We explicitly add wpasupplicant just in case.
apt-get install -y --install-recommends network-manager wpasupplicant

# Verify nmcli installed successfully
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
    echo "Backing up /etc/network/interfaces to prevent conflicts..."
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

if ! command -v docker &> /dev/null; then
    echo "Downloading Docker..."
    DOCKER_VERSION="24.0.7"
    curl -sSL "https://download.docker.com/linux/static/stable/aarch64/docker-\${DOCKER_VERSION}.tgz" -o docker.tgz

    echo "Extracting Docker..."
    tar xzf docker.tgz
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