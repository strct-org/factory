#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

echo "Entering chroot to install dependencies..."

cat <<'EOF' > $MOUNT_POINT/tmp/install_inside.sh
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "--- apt-get update ---"
apt-get update

echo "--- Installing networking tools required by strct-agent ---"
# hostapd        — creates WiFi AP (router + extender modes)
# dnsmasq        — DHCP + DNS + adblock address= directives
# iw             — WiFi interface control (scan, virtual AP creation)
# wireless-tools — iwconfig for tx power
# wpasupplicant  — wlan0 client mode (extender: connect to upstream AP)
# iptables       — NAT, firewall, port forwarding
# iproute2       — ip addr, ip link, ip neigh
# net-tools      — arp -a for device scanning
apt-get install -y \
    hostapd \
    dnsmasq \
    iw \
    wireless-tools \
    wpasupplicant \
    iptables \
    iproute2 \
    net-tools \
    curl \
    wget \
    ca-certificates

echo "--- Installing Tailscale ---"
curl -fsSL https://tailscale.com/install.sh | sh

echo "--- Configuring services ---"
# hostapd and dnsmasq are started ON DEMAND by strct-agent after it writes
# their config files. Enabling them at boot would cause them to start before
# the agent has written hostapd.conf / dnsmasq.conf, and they'd immediately
# fail or conflict.
systemctl disable hostapd || true
systemctl disable dnsmasq || true

# tailscaled must be running before `tailscale up` works.
# The agent calls `systemctl start tailscaled` before running `tailscale up`,
# but enabling it here means it also survives reboots automatically.
systemctl enable tailscaled || true

echo "--- Cleaning up ---"
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[OK] All dependencies installed."
EOF

chmod +x $MOUNT_POINT/tmp/install_inside.sh
chroot $MOUNT_POINT /bin/bash /tmp/install_inside.sh
rm $MOUNT_POINT/tmp/install_inside.sh

echo "[OK] Dependencies installed successfully."