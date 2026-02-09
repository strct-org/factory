#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------
# OPTIMIZATION PREP
# ----------------------------------------------------------------

# 1. Prevent services from trying to start inside Chroot (prevents timeouts)
echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# 2. Prevent installing documentation/man-pages (Saves massive CPU time)
cat <<NODOC > /etc/apt/apt.conf.d/01nodoc
DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };
APT::Install-Recommends "0";
APT::Install-Suggests "0";
Dir::Ignore-Files-Silently:: "(.save|.distupgrade)$";
Path-Exclude /usr/share/doc/*
Path-Exclude /usr/share/man/*
Path-Exclude /usr/share/groff/*
Path-Exclude /usr/share/info/*
Path-Exclude /usr/share/lintian/*
Path-Exclude /usr/share/linda/*
NODOC

# ----------------------------------------------------------------
# INSTALLATION
# ----------------------------------------------------------------

NEEDS_INSTALL=0
if ! command -v curl &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v wget &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v iptables &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v nmcli &> /dev/null; then NEEDS_INSTALL=1; fi  

if [ "\$NEEDS_INSTALL" -eq "1" ]; then
    echo "Running APT update..."
    # Only update, don't delete lists unless update fails
    apt-get update || (rm -rf /var/lib/apt/lists/* && apt-get update)

    echo "Installing minimal dependencies..."
    # --no-install-recommends is CRITICAL for speed
    apt-get install -y --no-install-recommends curl wget iptables network-manager ca-certificates
else
    echo " [SKIP] Tools are already installed."
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
    # Added -k (insecure) only if necessary, preferred to use ca-certificates
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
else
    echo " [SKIP] Docker already installed."
fi

# ----------------------------------------------------------------
# USER CONFIGURATION
# ----------------------------------------------------------------
echo "Configuring User 'martbul'..."

if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
fi

# Batch update passwords (faster than calling chpasswd twice)
echo "martbul:1234
root:1234" | chpasswd

usermod -aG sudo,docker martbul

# ----------------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------------

# Disable these services safely
systemctl disable unattended-upgrades.service 2>/dev/null || true
systemctl mask unattended-upgrades.service 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

# Remove the optimization blocks so the actual system runs normally
rm /usr/sbin/policy-rc.d
rm /etc/apt/apt.conf.d/01nodoc

echo "Cleaning up APT cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies & User Configuration complete."