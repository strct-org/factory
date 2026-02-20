#!/bin/bash
set -e

MOUNT_POINT="mnt_root"

: "${VPS_IP:?VPS_IP is not set}"
: "${VPS_PORT:?VPS_PORT is not set}"
: "${DOMAIN:?DOMAIN is not set}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

LOCAL_BINARY_PATH="../src/strct-agent-arm64"
LOCAL_FRPC_PATH="../src/frpc"
TARGET_DIR="$MOUNT_POINT/etc/strct"

echo "Checking for binaries..."
if [ ! -f "$LOCAL_BINARY_PATH" ]; then
    echo "[ERROR] Agent binary missing at $LOCAL_BINARY_PATH"
    exit 1
fi
if [ ! -f "$LOCAL_FRPC_PATH" ]; then
    echo "[ERROR] frpc binary missing at $LOCAL_FRPC_PATH"
    exit 1
fi

echo "Creating directories..."
mkdir -p "$TARGET_DIR"

echo "Copying binaries..."
cp "$LOCAL_BINARY_PATH" "$MOUNT_POINT/usr/local/bin/strct-agent"
chmod +x "$MOUNT_POINT/usr/local/bin/strct-agent"

cp "$LOCAL_FRPC_PATH" "$TARGET_DIR/frpc"
chmod +x "$TARGET_DIR/frpc"

echo "Injecting secrets into image .env..."
cat <<EOF > "$TARGET_DIR/.env"
VPS_IP=$VPS_IP
VPS_PORT=$VPS_PORT
DOMAIN=$DOMAIN
AUTH_TOKEN=$AUTH_TOKEN
EOF
chmod 600 "$TARGET_DIR/.env"

echo "Writing systemd service file..."
cat <<EOF > "$MOUNT_POINT/etc/systemd/system/strct-agent.service"
[Unit]
Description=Strct Agent
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/strct
ExecStart=/usr/local/bin/strct-agent
Restart=always
RestartSec=5s
# Redirect stdout/stderr to journald
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling strct-agent service via symlink (no chroot needed)..."
# This is exactly what 'systemctl enable' does — creates a symlink in
# multi-user.target.wants pointing at the service file.
WANTS_DIR="$MOUNT_POINT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS_DIR"
ln -sf /etc/systemd/system/strct-agent.service \
    "$WANTS_DIR/strct-agent.service"

echo "Updating PARTUUIDs to ensure correct boot..."
ROOT_DEV=$(findmnt -n -o SOURCE --target "$MOUNT_POINT")
if [ -z "$ROOT_DEV" ]; then
    echo "[ERROR] Could not find mounted loop device for UUID update."
    exit 1
fi

BOOT_DEV="${ROOT_DEV%p2}p1"
CURRENT_UUID=$(blkid -o value -s PARTUUID "$ROOT_DEV")
BOOT_UUID=$(blkid -o value -s PARTUUID "$BOOT_DEV")

if [ -z "$CURRENT_UUID" ] || [ -z "$BOOT_UUID" ]; then
    echo "[ERROR] Failed to fetch UUIDs."
    exit 1
fi

echo "Root P2 PARTUUID: $CURRENT_UUID"
echo "Boot P1 PARTUUID: $BOOT_UUID"

# Handle both Bookworm (/boot/firmware) and Bullseye (/boot) layouts
CMDLINE_PATH="$MOUNT_POINT/boot/firmware/cmdline.txt"
[ -f "$MOUNT_POINT/boot/cmdline.txt" ] && CMDLINE_PATH="$MOUNT_POINT/boot/cmdline.txt"

sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=$CURRENT_UUID/" "$CMDLINE_PATH"
sed -i "s/PARTUUID=[^ ]*[ \t]*\/[ \t]/PARTUUID=$CURRENT_UUID \/ /" "$MOUNT_POINT/etc/fstab"
sed -i "s/PARTUUID=[^ ]*[ \t]*\/boot/PARTUUID=$BOOT_UUID \/boot/" "$MOUNT_POINT/etc/fstab"

echo "[OK] Agent baked in successfully."