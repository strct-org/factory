#!/bin/bash
set -euo pipefail
MOUNT_POINT="mnt_root"

if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: Directory $MOUNT_POINT does not exist."
    exit 1
fi

echo "Mounting system directories..."
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"
mkdir -p "$MOUNT_POINT/tmp"
chmod 1777 "$MOUNT_POINT/tmp"

cat <<'EOF' > "$MOUNT_POINT/tmp/install_fast.sh"
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

mkdir -p /var/lib/man-db
touch /var/lib/man-db/auto-update

echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

APT_FLAGS="-o Acquire::IndexTargets::deb::cnf-Metadata=false -o APT::Sandbox::User=root -o Acquire::Languages=none -o Acquire::http::No-Cache=true"

rm -rf /var/lib/apt/lists/*
apt-get update $APT_FLAGS
apt-get install -y $APT_FLAGS --no-install-recommends eatmydata

eatmydata apt-get install -y --no-install-recommends $APT_FLAGS \
    network-manager \
    wpasupplicant \
    curl \
    wget \
    ca-certificates \
    iptables \
    dnsutils \
    rfkill \
    iw

command -v nmcli >/dev/null || { echo "[ERROR] nmcli failed to install."; exit 1; }

rm -f /etc/netplan/*.yaml
cat <<NETPLAN > /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
NETPLAN
chmod 600 /etc/netplan/01-network-manager-all.yaml

systemctl disable systemd-networkd || true
systemctl mask systemd-networkd || true
systemctl stop systemd-networkd || true

systemctl disable wpa_supplicant || true
systemctl mask wpa_supplicant || true

systemctl enable NetworkManager

if [ -f /etc/network/interfaces ]; then
    mv /etc/network/interfaces /etc/network/interfaces.bak
    printf "auto lo\niface lo inet loopback\n" > /etc/network/interfaces
fi

if ! id "martbul" &>/dev/null; then
    useradd -m -s /bin/bash martbul
    echo "martbul:1234" | chpasswd
    usermod -aG sudo martbul
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /usr/sbin/policy-rc.d /var/lib/man-db/auto-update
EOF

chmod +x "$MOUNT_POINT/tmp/install_fast.sh"
chroot "$MOUNT_POINT" /bin/bash /tmp/install_fast.sh
rm -f "$MOUNT_POINT/tmp/install_fast.sh"

umount "$MOUNT_POINT/dev/pts" || true
umount "$MOUNT_POINT/dev" || true
umount "$MOUNT_POINT/proc" || true
umount "$MOUNT_POINT/sys" || true

echo "[OK] Build Complete. Networking conflicts resolved."
