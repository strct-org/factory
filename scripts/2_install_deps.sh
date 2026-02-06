#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------
# SPEED OPTIMIZATION: Check if tools exist before updating APT
# ----------------------------------------------------------------
# Joshua Riek's images are "Server" builds, so they usually 
# already have curl, wget, and iptables. 
# If they exist, we SKIP 'apt-get update' entirely (Saving ~19 mins).

NEEDS_INSTALL=0
if ! command -v curl &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v wget &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v iptables &> /dev/null; then NEEDS_INSTALL=1; fi

if [ "\$NEEDS_INSTALL" -eq "1" ]; then
    echo "Tools missing. Running optimized APT update..."
    
    # 1. Clear old lists to prevent CPU-intensive 'merging' of data
    rm -rf /var/lib/apt/lists/*

    # 2. Run Update with flags to DISABLE heavy CPU tasks:
    # - Acquire::Languages=none : Don't download/hash English translations (Huge speedup)
    # - Acquire::PDiffs=false   : Download full list instead of patching (Patching is slow in QEMU)
    # - Dir::Cache::pkgcache="" : Disable binary cache generation (CPU heavy)
    apt-get update \
        -o Acquire::Languages=none \
        -o Acquire::PDiffs=false \
        -o Dir::Cache::pkgcache="" \
        -o Dir::Cache::srcpkgcache=""

    echo "Installing minimal dependencies..."
    apt-get install -y curl wget iptables
else
    echo " [SKIP] curl, wget, and iptables are already installed. Skipping APT update."
fi

# ----------------------------------------------------------------
# INSTALL DOCKER (Static Binaries)
# ----------------------------------------------------------------
# We still use static binaries because 'apt-get install docker.io' 
# triggers man-db processing which is also slow.

if ! command -v docker &> /dev/null; then
    echo "Downloading Docker Static Binaries..."
    DOCKER_VERSION="24.0.7"
    # Use -k in case certificates are missing (rare but possible in minimal envs)
    curl -k -sSL "https://download.docker.com/linux/static/stable/aarch64/docker-\${DOCKER_VERSION}.tgz" -o docker.tgz

    echo "Extracting Docker..."
    tar xzvf docker.tgz
    cp docker/* /usr/bin/
    rm -rf docker docker.tgz

    # Create Group and Service
    groupadd docker || true

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
# FINAL CLEANUP & OPTIMIZATION
# ----------------------------------------------------------------

# Disable Unattended Upgrades (Prevents 100% CPU usage on first boot)
systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

# Disable 'Wait for Network' (Prevents boot hang if no ethernet cable)
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true

echo "Cleaning up..."
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies processing complete."