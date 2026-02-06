#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

echo "Running apt-get update..."
apt-get update

# 1. Install minimal tools (iptables is required for Docker)
# We SKIP network-manager to avoid conflicts with Ubuntu's Netplan
apt-get install -y curl wget iptables

# 2. Install Docker manually (Static Binaries) - MASSIVE SPEEDUP
# Apt installation in QEMU takes 20+ mins. This takes 10 seconds.
echo "Downloading Docker Static Binaries..."
DOCKER_VERSION="24.0.7"
curl -sSL "https://download.docker.com/linux/static/stable/aarch64/docker-\${DOCKER_VERSION}.tgz" -o docker.tgz

echo "Extracting Docker..."
tar xzvf docker.tgz
cp docker/* /usr/bin/
rm -rf docker docker.tgz

# 3. Create Docker Group and Service
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

# 4. Disable heavy first-boot tasks (Fixes the 20-minute boot delay)
echo "Disabling Unattended Upgrades..."
systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

echo "Disabling 'Wait for Network' (Prevents boot hang if no ethernet)..."
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true

echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies installed (Fast Mode)."