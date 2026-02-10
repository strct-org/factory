#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# Safety check
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Injecting First-Boot Provisioning Script..."

# ----------------------------------------------------------------
# 1. CREATE THE SETUP SCRIPT
# ----------------------------------------------------------------
# This script sits inside the image and waits for the Pi to boot.
cat <<EOF > $MOUNT_POINT/usr/local/bin/provision_device.sh
#!/bin/bash
# Log output for debugging
exec > /var/log/provision.log 2>&1

echo "Starting First Boot Provisioning..."

# 1. Wait for Internet (Generic check)
echo "Waiting for internet connection..."
until ping -c1 8.8.8.8 &>/dev/null; do :; done

# 2. Install Packages (Runs at NATIVE Speed on the Pi)
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables

# 3. Configure Network Manager
systemctl enable NetworkManager
if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

# 4. Create User 'martbul'
if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo martbul
fi

echo "Provisioning Complete. Self-destructing service..."

# 5. Disable this service so it never runs again
systemctl disable provision_device.service
EOF

# Make the script executable
chmod +x $MOUNT_POINT/usr/local/bin/provision_device.sh

# ----------------------------------------------------------------
# 2. CREATE THE SYSTEMD SERVICE
# ----------------------------------------------------------------
# This tells Linux to run the script above when it boots.

cat <<EOF > $MOUNT_POINT/etc/systemd/system/provision_device.service
[Unit]
Description=First Boot Provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/provision_device.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------
# 3. ENABLE THE SERVICE (MANUALLY)
# ----------------------------------------------------------------
# Since we are not in Chroot, we manually create the symlink systemctl would create.

mkdir -p $MOUNT_POINT/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/provision_device.service \
       $MOUNT_POINT/etc/systemd/system/multi-user.target.wants/provision_device.service

echo "[OK] Build Complete in 1 second."
echo "Flash the image. When you plug it in, it will install dependencies automatically."