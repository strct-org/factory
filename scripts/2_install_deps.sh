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

echo "--- Installing networking tools ---"
# hostapd   — creates the WiFi AP (router/extender mode)
# dnsmasq   — DHCP server + DNS forwarder + adblock address= directives
# iw        — query/configure WiFi interfaces (scan, virtual AP creation)
# wireless-tools  — iwconfig (tx power), iwlist
# wpasupplicant   — wlan0 client mode (extender: connect to upstream)
# iptables  — NAT, firewall, port forwarding
# iproute2  — ip addr, ip link, ip neigh
# net-tools — arp -a (device scanning)
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
# hostapd and dnsmasq are started on demand by the agent.
# Leaving them enabled at boot would conflict with the agent's own startup
# sequence (agent writes the conf files THEN starts them).
systemctl disable hostapd || true
systemctl disable dnsmasq || true

# tailscaled must be running before `tailscale up` can work.
# The agent calls `systemctl start tailscaled` before running tailscale up,
# but enabling it here means it survives reboots without the agent having
# to manage the daemon lifecycle.
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