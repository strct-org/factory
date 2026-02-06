#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

echo "Running apt-get update..."
apt-get update

echo "Installing Docker and utilities..."
# Armbian/Orange Pi usually has docker in standard repos
apt-get install -y docker.io network-manager curl wget

echo "Enabling Docker service..."
systemctl enable docker

echo "Cleaning up package cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies installed successfully."