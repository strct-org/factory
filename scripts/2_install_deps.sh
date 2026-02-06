#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# OPTIMIZATION 1: Disable Man Pages & Docs
# ---------------------------------------------------------
# Writing documentation files in QEMU is very slow. We skip them.
echo "path-exclude /usr/share/doc/*" > /etc/dpkg/dpkg.cfg.d/01_nodoc
echo "path-exclude /usr/share/man/*" >> /etc/dpkg/dpkg.cfg.d/01_nodoc
echo "path-exclude /usr/share/groff/*" >> /etc/dpkg/dpkg.cfg.d/01_nodoc
echo "path-exclude /usr/share/info/*" >> /etc/dpkg/dpkg.cfg.d/01_nodoc

echo "Running apt-get update..."
apt-get update

# ---------------------------------------------------------
# OPTIMIZATION 2: Install 'eatmydata' first
# ---------------------------------------------------------
# This tool disables fsync(), making I/O inside QEMU much faster.
apt-get install -y eatmydata

echo "Installing Docker and utilities (Optimized)..."

# ---------------------------------------------------------
# OPTIMIZATION 3: Use eatmydata + --no-install-recommends
# ---------------------------------------------------------
# - eatmydata: Speeds up unpacking
# - no-install-recommends: Skips heavy optional packages (like git, cgroup-mounts, python parts)
# - network-manager: Only install if you definitely need it over standard netplan
eatmydata apt-get install -y --no-install-recommends docker.io network-manager curl wget

echo "Enabling Docker service..."
systemctl enable docker

echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
# Remove the nodoc config so the final user gets docs if they install things later (optional)
rm /etc/dpkg/dpkg.cfg.d/01_nodoc
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh

# execute the script inside the image
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh

rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies installed successfully."