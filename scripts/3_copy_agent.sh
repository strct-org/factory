#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ── Required env vars ────────────────────────────────────────────────────────
: "${VPS_IP:?VPS_IP is not set}"
: "${VPS_PORT:?VPS_PORT is not set}"
: "${DOMAIN:?DOMAIN is not set}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

LOCAL_BINARY_PATH="../src/strct-agent-arm64"
LOCAL_FRPC_PATH="../src/frpc"
TARGET_DIR="$MOUNT_POINT/etc/strct"

# ── Verify binaries exist before doing anything ───────────────────────────────
echo "Checking for binaries..."
if [ ! -f "$LOCAL_BINARY_PATH" ]; then
    echo "[ERROR] Agent binary missing at $LOCAL_BINARY_PATH"
    exit 1
fi
if [ ! -f "$LOCAL_FRPC_PATH" ]; then
    echo "[ERROR] frpc binary missing at $LOCAL_FRPC_PATH"
    exit 1
fi

# ── Copy binaries ─────────────────────────────────────────────────────────────
echo "Creating target directory..."
mkdir -p "$TARGET_DIR"

echo "Copying agent binary..."
cp "$LOCAL_BINARY_PATH" "$MOUNT_POINT/usr/local/bin/strct-agent"
chmod +x "$MOUNT_POINT/usr/local/bin/strct-agent"

echo "Copying frpc binary..."
cp "$LOCAL_FRPC_PATH" "$TARGET_DIR/frpc"
chmod +x "$TARGET_DIR/frpc"

# ── Write .env ────────────────────────────────────────────────────────────────
echo "Writing .env file..."
cat <<EOF > "$TARGET_DIR/.env"
VPS_IP=$VPS_IP
VPS_PORT=$VPS_PORT
DOMAIN=$DOMAIN
AUTH_TOKEN=$AUTH_TOKEN
EOF
chmod 600 "$TARGET_DIR/.env"

# ── Write systemd service ─────────────────────────────────────────────────────
# After=network.target (not network-online.target) avoids the 90s boot stall
# when no ethernet cable is plugged in. The agent handles connection retries
# internally.
#
# Docker dependency removed — the agent doesn't use Docker.
echo "Writing systemd service file..."
cat <<EOF > "$MOUNT_POINT/etc/systemd/system/strct-agent.service"
[Unit]
Description=Strct Agent
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/strct
ExecStart=/usr/local/bin/strct-agent
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling systemd service..."
chroot $MOUNT_POINT systemctl enable strct-agent.service

# ── Fix PARTUUIDs ─────────────────────────────────────────────────────────────
# Determine the loop device from the image file directly.
# This is more reliable than inferring from findmnt, which can return bind
# mounts or symlinks that break the ${VAR%p2}p1 suffix stripping.
echo "Locating loop device for work_image.img..."
LOOP_DEV=$(losetup -j "../work_image.img" | cut -d: -f1)

if [ -z "$LOOP_DEV" ]; then
    echo "[ERROR] Could not find loop device for ../work_image.img"
    echo "        Is 1_mount.sh still set up? Run losetup -a to check."
    exit 1
fi

ROOT_DEV="${LOOP_DEV}p2"
BOOT_DEV="${LOOP_DEV}p1"

echo "Loop device : $LOOP_DEV"
echo "Root device : $ROOT_DEV"
echo "Boot device : $BOOT_DEV"

CURRENT_UUID=$(blkid -o value -s PARTUUID "$ROOT_DEV")
BOOT_UUID=$(blkid -o value -s PARTUUID "$BOOT_DEV")

# Fail loudly rather than writing empty/corrupt values into cmdline.txt/fstab.
# An empty PARTUUID produces `root=PARTUUID=` which the bootloader rejects
# silently — the Pi just shows the logo and hangs.
if [ -z "$CURRENT_UUID" ]; then
    echo "[ERROR] Got empty PARTUUID for root partition ($ROOT_DEV)"
    echo "        Run: blkid $ROOT_DEV"
    exit 1
fi
if [ -z "$BOOT_UUID" ]; then
    echo "[ERROR] Got empty PARTUUID for boot partition ($BOOT_DEV)"
    echo "        Run: blkid $BOOT_DEV"
    exit 1
fi

echo "Root PARTUUID: $CURRENT_UUID"
echo "Boot PARTUUID: $BOOT_UUID"

# Raspberry Pi OS Bookworm puts cmdline.txt in /boot/firmware;
# older Bullseye images put it in /boot.
CMDLINE_PATH="$MOUNT_POINT/boot/cmdline.txt"
if [ -f "$MOUNT_POINT/boot/firmware/cmdline.txt" ]; then
    CMDLINE_PATH="$MOUNT_POINT/boot/firmware/cmdline.txt"
fi

echo "Updating cmdline.txt at: $CMDLINE_PATH"
sed -i "s|root=PARTUUID=[^ ]*|root=PARTUUID=$CURRENT_UUID|" "$CMDLINE_PATH"

echo "Updating fstab..."
# Replace root partition PARTUUID (mounted at /)
sed -i "s|PARTUUID=[^ ]*\s*/\s|PARTUUID=$CURRENT_UUID /|" "$MOUNT_POINT/etc/fstab"
# Replace boot partition PARTUUID (mounted at /boot or /boot/firmware)
sed -i "s|PARTUUID=[^ ]*\s*/boot|PARTUUID=$BOOT_UUID /boot|" "$MOUNT_POINT/etc/fstab"

# ── Print final state for CI log inspection ───────────────────────────────────
# If the Pi still boots to a logo, check the Actions log for these values.
echo ""
echo "=== cmdline.txt (verify root=PARTUUID is non-empty) ==="
cat "$CMDLINE_PATH"
echo ""
echo "=== /etc/fstab (verify both PARTUUIDs match above) ==="
cat "$MOUNT_POINT/etc/fstab"
echo "========================================================"
echo ""

echo "[OK] Agent baked in successfully."