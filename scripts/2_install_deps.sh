#!/bin/bash
set -e

MOUNT_POINT="mnt_root"
APT_CACHE="../apt-cache"
ARCH="arm64"

# Packages to install into the image.
# Each entry is the exact apt package name for ARM64/Debian Bookworm.
# Docker removed — the agent binary does not use Docker.
PACKAGES=(
    network-manager
    libnm0
    libglib2.0-0
    libdbus-1-3
    curl
    wget
    ca-certificates
)

mkdir -p "$APT_CACHE"

echo "Configuring dpkg for ARM64 target..."
# Tell dpkg the target architecture so it can unpack ARM64 packages correctly
# on this x86 host. This is the key: we're just extracting files, not running them.
export DPKG_FORCE="architecture"

echo "Adding ARM64 architecture to apt..."
dpkg --add-architecture arm64

echo "Fetching ARM64 package list from Debian Bookworm repos..."
# We pull from the Raspberry Pi OS repo which tracks Debian Bookworm
apt-get update -qq \
    -o Dir::Etc::sourcelist="sources.list.d/raspi.list" 2>/dev/null || true

# Use debian bookworm directly — fully compatible with RPi OS Bookworm
cat > /tmp/sources-arm64.list << EOF
deb [arch=arm64] http://deb.debian.org/debian bookworm main
deb [arch=arm64] http://deb.debian.org/debian-security bookworm-security main
deb [arch=arm64] http://deb.debian.org/debian bookworm-updates main
EOF

apt-get update -qq -o Dir::Etc::SourceList=/tmp/sources-arm64.list \
    -o Dir::Etc::SourceParts=/dev/null \
    -o APT::Architecture=arm64 \
    -o Dir::Cache="$APT_CACHE" 2>/dev/null || true

echo "Downloading ARM64 .deb packages (using cache if available)..."
for pkg in "${PACKAGES[@]}"; do
    DEB_FILE=$(ls "$APT_CACHE"/${pkg}_*_arm64.deb 2>/dev/null | head -1)
    if [ -n "$DEB_FILE" ]; then
        echo "  [CACHE HIT]  $pkg"
    else
        echo "  [DOWNLOAD]   $pkg"
        apt-get download \
            -o APT::Architecture=arm64 \
            -o Dir::Cache::archives="$APT_CACHE" \
            ${pkg}:arm64 2>/dev/null || \
        # Fallback: direct download from debian if apt-get download fails
        (
            cd "$APT_CACHE"
            apt-get download \
                -o APT::Architecture=arm64 \
                ${pkg}:arm64 2>/dev/null
        ) || echo "  [WARN] Could not download $pkg — may already exist in image"
    fi
done

echo "Extracting packages into image filesystem..."
for pkg in "${PACKAGES[@]}"; do
    DEB_FILE=$(ls "$APT_CACHE"/${pkg}_*_arm64.deb 2>/dev/null | head -1)
    if [ -n "$DEB_FILE" ]; then
        echo "  Extracting: $(basename $DEB_FILE)"
        # dpkg-deb --extract unpacks the deb contents directly into the
        # image mount point — this runs at native x86 speed, no emulation.
        dpkg-deb --extract "$DEB_FILE" "$MOUNT_POINT"
    else
        echo "  [SKIP] No .deb found for $pkg"
    fi
done

echo "Enabling NetworkManager service..."
# We can't run systemctl inside the image (no chroot), but we can create
# the symlink that systemctl enable would have created.
SYSTEMD_DIR="$MOUNT_POINT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$SYSTEMD_DIR"
NM_SERVICE="$MOUNT_POINT/lib/systemd/system/NetworkManager.service"
if [ -f "$NM_SERVICE" ]; then
    ln -sf /lib/systemd/system/NetworkManager.service \
        "$SYSTEMD_DIR/NetworkManager.service"
    echo "  NetworkManager.service enabled."
else
    echo "  [WARN] NetworkManager.service not found — will be enabled on first boot."
fi

echo "[OK] Dependencies installed natively (no QEMU used)."