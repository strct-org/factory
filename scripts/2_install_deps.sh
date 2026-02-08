#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering Chroot to install dependencies..."

cat <<EOF > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

NEEDS_INSTALL=0
if ! command -v curl &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v wget &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v iptables &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v nmcli &> /dev/null; then NEEDS_INSTALL=1; fi  


if [ "\$NEEDS_INSTALL" -eq "1" ]; then
    echo "Tools missing. Running optimized APT update..."
    # Clear lists to ensure we get fresh metadata if needed
    rm -rf /var/lib/apt/lists/*
    apt-get update

    echo "Installing minimal dependencies & Network Manager..."
    # Added network-manager here
    apt-get install -y curl wget iptables network-manager
else
    echo " [SKIP] Tools are already installed."
fi

echo "Configuring Network Manager..."
systemctl enable NetworkManager

# IMPORTANT: If wlan0 is defined in /etc/network/interfaces, 
# NetworkManager will ignore it. We must clear it to allow nmcli to work.
if [ -f /etc/network/interfaces ]; then
    echo "Backing up and clearing /etc/network/interfaces..."
    mv /etc/network/interfaces /etc/network/interfaces.bak
    # Write a minimal file that only handles localhost
    echo -e "auto lo\niface lo inet loopback" > /etc/network/interfaces
fi



if ! command -v docker &> /dev/null; then
    echo "Downloading Docker Static Binaries..."
    DOCKER_VERSION="24.0.7"
    curl -k -sSL "https://download.docker.com/linux/static/stable/aarch64/docker-\${DOCKER_VERSION}.tgz" -o docker.tgz

    echo "Extracting Docker..."
    tar xzvf docker.tgz
    cp docker/* /usr/bin/
    rm -rf docker docker.tgz

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
# USER CONFIGURATION (Martbul)
# ----------------------------------------------------------------
echo "Configuring User 'martbul'..."

# 1. Create the user if they don't exist
# -m creates the /home/martbul directory
# -s /bin/bash ensures you have a proper shell
if id "martbul" &>/dev/null; then
    echo "User martbul exists, updating password..."
else
    useradd -m -s /bin/bash martbul
fi

# 2. Set the password for 'martbul'
echo "martbul:1234" | chpasswd

# 3. Add to 'sudo' group (Grants Administrator/Root access)
usermod -aG sudo martbul

# 4. Add to 'docker' group (Allows running docker without typing sudo)
usermod -aG docker martbul

# 5. Set Root password to '1234' as well (Just in case)
echo "root:1234" | chpasswd

# ----------------------------------------------------------------
# FINAL CLEANUP & OPTIMIZATION
# ----------------------------------------------------------------

systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true

echo "Cleaning up..."
rm -rf /var/lib/apt/lists/*
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies & User Configuration complete."