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
cat <<EOF > $MOUNT_POINT/usr/local/bin/provision_device.sh
#!/bin/bash
# Log output for debugging
exec > /var/log/provision.log 2>&1

echo "Starting First Boot Provisioning..."

# --- STEP 1: CREATE USER (Do this FIRST so you can login!) ---
if ! id "martbul" &>/dev/null; then
    echo "Creating user martbul..."
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo martbul
    echo "[OK] User created."
fi

# --- STEP 2: CONFIGURE NETWORK MANAGER (Do this SECOND) ---
# We enable it now so it can help us get online
systemctl enable NetworkManager --now

if [ -f /etc/network/interfaces ]; then
    # Backup interfaces file to let NetworkManager manage the device
    mv /etc/network/interfaces /etc/network/interfaces.bak
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi

# --- STEP 3: WAIT FOR INTERNET & INSTALL PACKAGES ---
echo "Waiting for internet connection..."

# Loop for up to 5 minutes waiting for internet
MAX_RETRIES=30
COUNT=0
while ! ping -c1 8.8.8.8 &>/dev/null; do
    echo "Waiting for internet... (\$COUNT/\$MAX_RETRIES)"
    sleep 5
    ((COUNT++))
    if [ \$COUNT -ge \$MAX_RETRIES ]; then
        echo "No internet after 2.5 minutes. Skipping package install."
        # We exit, but do NOT disable the service, so it tries again next boot
        exit 1
    fi
done

echo "Internet found. Installing packages..."
export DEBIAN_FRONTEND=noninteractive

# Update and Install
apt-get update
apt-get install -y --no-install-recommends \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables

echo "Provisioning Complete. Self-destructing service..."
systemctl disable provision_device.service
EOF

# Make the script executable
chmod +x $MOUNT_POINT/usr/local/bin/provision_device.sh

# ----------------------------------------------------------------
# 2. CREATE THE SYSTEMD SERVICE
# ----------------------------------------------------------------
# CHANGED: We removed 'After=network-online.target' so it runs earlier.
cat <<EOF > $MOUNT_POINT/etc/systemd/system/provision_device.service
[Unit]
Description=First Boot Provisioning
# Run early, don't wait for full network, so user is created fast
After=local-fs.target 

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/provision_device.sh
# If it fails (no internet), try again later
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------
# 3. ENABLE THE SERVICE (MANUALLY)
# ----------------------------------------------------------------
mkdir -p $MOUNT_POINT/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/provision_device.service \
       $MOUNT_POINT/etc/systemd/system/multi-user.target.wants/provision_device.service

echo "[OK] Build Complete."
echo "Flash the image."
echo "1. On first boot, you will be able to login as martbul IMMEDIATELY."
echo "2. The background script will keep trying to connect to install packages."