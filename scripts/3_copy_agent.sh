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

# ---------------------------------------------------------
# CRITICAL FIX: SERVICE TIMING
# ---------------------------------------------------------
echo "Creating Service File..."
cat <<EOF > strct_agent.service
[Unit]
Description=Strct Agent
# Wait for NM to be fully up. 'network-online' is often not enough.
After=network.target NetworkManager.service
Requires=NetworkManager.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/strct
# Add a delay to allow Broadcom Wi-Fi firmware to initialize (Prevents Error -52)
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/cloud-agent
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

mv strct_agent.service $MOUNT_POINT/etc/systemd/system/
chroot $MOUNT_POINT systemctl enable strct_agent.service

# ---------------------------------------------------------
# CRITICAL FIX: Disable Cloud-Init Resize
# ---------------------------------------------------------
# We already resized the partition in Step 1 using 'parted'.
echo "Disabling Cloud-Init Disk Setup..."
echo "datasource_list: [ None ]" > $MOUNT_POINT/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "cloud_init_modules:
 - migrator
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - ca-certs
 - rsyslog
 - users-groups
 - ssh
" > $MOUNT_POINT/etc/cloud/cloud.cfg.d/99-disable-resize.cfg

echo "[OK] Agent baked in & Service timing optimized."