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
if [ ! -f "$LOCAL_BINARY_PATH" ]; then echo "[ERROR] Agent binary missing at $LOCAL_BINARY_PATH"; exit 1; fi
if [ ! -f "$LOCAL_FRPC_PATH" ]; then echo "[ERROR] frpc binary missing at $LOCAL_FRPC_PATH"; exit 1; fi

echo "Creating directories..."
mkdir -p "$TARGET_DIR"

echo "Copying binaries..."
cp "$LOCAL_BINARY_PATH" "$MOUNT_POINT/usr/local/bin/cloud-agent"
chmod +x "$MOUNT_POINT/usr/local/bin/cloud-agent"

cp "$LOCAL_FRPC_PATH" "$TARGET_DIR/frpc"
chmod +x "$TARGET_DIR/frpc"

echo "Injecting Secrets into Image .env..."
cat <<EOF > "$TARGET_DIR/.env"
VPS_IP=$VPS_IP
VPS_PORT=$VPS_PORT
DOMAIN=$DOMAIN
AUTH_TOKEN=$AUTH_TOKEN
EOF
chmod 600 "$TARGET_DIR/.env"

echo "Creating Service File..."
cat <<EOF > strct_agent.service
[Unit]
Description=Strct Agent
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=root
# IMPORTANT: Sets the folder so the app can find .env and ./frpc
WorkingDirectory=/etc/strct
ExecStart=/usr/local/bin/cloud-agent
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "Copying Service file to image..."
cp strct_agent.service $MOUNT_POINT/etc/systemd/system/
rm strct_agent.service

echo "Enabling systemd service..."
chroot $MOUNT_POINT systemctl enable strct_agent.service

echo "Updating PARTUUIDs to ensure boot..."

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

echo "Root P2 UUID: $CURRENT_UUID"
echo "Boot P1 UUID: $BOOT_UUID"

CMDLINE_PATH="$MOUNT_POINT/boot/cmdline.txt"
[ -f "$MOUNT_POINT/boot/firmware/cmdline.txt" ] && CMDLINE_PATH="$MOUNT_POINT/boot/firmware/cmdline.txt"

sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=$CURRENT_UUID/" "$CMDLINE_PATH"

sed -i "s/PARTUUID=[^ ]*[ \t]*\/[ \t]/PARTUUID=$CURRENT_UUID \/ /" "$MOUNT_POINT/etc/fstab"
sed -i "s/PARTUUID=[^ ]*[ \t]*\/boot/PARTUUID=$BOOT_UUID \/boot/" "$MOUNT_POINT/etc/fstab"

echo "[OK] UUIDs updated. Agent baked in successfully."