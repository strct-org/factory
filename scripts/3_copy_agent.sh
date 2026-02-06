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
if [ ! -f "$LOCAL_BINARY_PATH" ]; then echo "[ERROR] Agent binary missing"; exit 1; fi
if [ ! -f "$LOCAL_FRPC_PATH" ]; then echo "[ERROR] frpc binary missing"; exit 1; fi

echo "Creating directories..."
mkdir -p "$TARGET_DIR"

echo "Copying binaries..."
cp "$LOCAL_BINARY_PATH" "$MOUNT_POINT/usr/local/bin/cloud-agent"
chmod +x "$MOUNT_POINT/usr/local/bin/cloud-agent"

cp "$LOCAL_FRPC_PATH" "$TARGET_DIR/frpc"
chmod +x "$TARGET_DIR/frpc"

echo "Injecting Secrets..."
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
WorkingDirectory=/etc/strct
ExecStart=/usr/local/bin/cloud-agent
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

mv strct_agent.service $MOUNT_POINT/etc/systemd/system/

echo "Enabling systemd service..."
chroot $MOUNT_POINT systemctl enable strct_agent.service

echo "[OK] Agent baked in successfully."