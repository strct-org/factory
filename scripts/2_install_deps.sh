#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

# We write a temporary script inside the image to run commands
cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# 1. Update Apt
apt-get update

# 2. Install Docker
apt-get install -y docker.io network-manager

# 3. Enable Docker to start on boot
systemctl enable docker

# 4. Clean up to save space
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh

# EXECUTE inside the image
sudo chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh

# Remove the temp script
rm $MOUNT_POINT/tmp/install_inside.sh

echo "Dependencies installed successfully."