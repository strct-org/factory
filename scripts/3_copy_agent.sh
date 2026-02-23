#!/bin/bash
set -e
MOUNT_POINT="mnt_root"

# ── Required env vars ─────────────────────────────────────────────────────────
: "${VPS_IP:?VPS_IP is not set}"
: "${VPS_PORT:?VPS_PORT is not set}"
: "${DOMAIN:?DOMAIN is not set}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

LOCAL_BINARY_PATH="../src/strct-agent-arm64"
LOCAL_FRPC_PATH="../src/frpc"
TARGET_DIR="$MOUNT_POINT/etc/strct"

# ── Verify binaries before doing anything ─────────────────────────────────────
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
echo "Writing .env..."
cat <<EOF > "$TARGET_DIR/.env"
VPS_IP=$VPS_IP
VPS_PORT=$VPS_PORT
DOMAIN=$DOMAIN
AUTH_TOKEN=$AUTH_TOKEN
EOF
chmod 600 "$TARGET_DIR/.env"

# ── Write systemd service ─────────────────────────────────────────────────────
# After=network.target avoids the 90s boot stall that network-online.target
# causes when no ethernet cable is plugged in.
# Docker dependency removed — strct-agent does not use Docker.
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

# ── Boot config note ──────────────────────────────────────────────────────────
# Orange Pi uses U-Boot, NOT Raspberry Pi's cmdline.txt/fstab PARTUUID system.
# U-Boot finds the root partition by partition number (partition 2), not by a
# PARTUUID in a text file. cmdline.txt does not exist on this board.
# Patching PARTUUIDs is NOT required and NOT applicable here — skipping.
echo "Skipping PARTUUID fixup — Orange Pi uses U-Boot (no cmdline.txt)."

echo ""
echo "=== /etc/fstab (informational only) ==="
cat "$MOUNT_POINT/etc/fstab" || true
echo "========================================"

echo "[OK] Agent baked in successfully."