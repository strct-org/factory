#!/bin/bash
set -e

MOUNT_POINT="mnt_root"
APT_CACHE="../apt-cache"

# Packages to add on top of the base RPi OS image.
# Note: network-manager, curl, wget, ca-certificates are already present
# in the Raspberry Pi OS Bookworm Lite base image. Only list packages that
# are genuinely missing from the base. Add more here as needed.
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

# ---------------------------------------------------------------------------
# Set up an isolated apt sources config pointing at Debian Bookworm ARM64.
# We use apt-get download (not apt-get install --download-only) because:
#   - apt-get download needs NO dpkg lock, NO dpkg database, NO root dpkg state
#   - apt-get install --download-only requires a full dpkg environment
# ---------------------------------------------------------------------------
echo "Setting up isolated apt environment for ARM64 downloads..."

TMP_APT=$(mktemp -d)
trap "rm -rf '$TMP_APT'" EXIT

mkdir -p "$TMP_APT/etc/apt/trusted.gpg.d"
mkdir -p "$TMP_APT/var/lib/apt/lists/partial"
mkdir -p "$TMP_APT/var/cache/apt/archives/partial"

cat > "$TMP_APT/etc/apt/sources.list" << 'EOF'
deb [arch=arm64] http://deb.debian.org/debian bookworm main contrib
deb [arch=arm64] http://deb.debian.org/debian-security bookworm-security main
deb [arch=arm64] http://deb.debian.org/debian bookworm-updates main
EOF

# Get the Debian archive keyring — needed to verify package signatures.
# Ubuntu runners have it as debian-archive-keyring, install if missing.
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    cp /usr/share/keyrings/debian-archive-keyring.gpg \
        "$TMP_APT/etc/apt/trusted.gpg.d/"
else
    apt-get install -y -qq debian-archive-keyring 2>/dev/null || true
    if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
        cp /usr/share/keyrings/debian-archive-keyring.gpg \
            "$TMP_APT/etc/apt/trusted.gpg.d/"
    fi
fi

APT_OPTS=(
    -o Dir="$TMP_APT"
    -o Dir::Etc::SourceList="$TMP_APT/etc/apt/sources.list"
    -o Dir::Etc::SourceParts="/dev/null"
    -o Dir::Etc::Trusted="$TMP_APT/etc/apt/trusted.gpg.d"
    -o Dir::Cache="$TMP_APT/var/cache/apt"
    -o Dir::State="$TMP_APT/var/lib/apt"
    -o APT::Architecture="arm64"
    -o APT::Architectures="arm64"
    # Suppress the sandboxing warning (we're root, that's fine here)
    -o APT::Sandbox::User="root"
)

echo "Updating ARM64 package lists from Debian Bookworm..."
apt-get "${APT_OPTS[@]}" update

echo "Downloading ARM64 .deb packages..."
for pkg in "${PACKAGES[@]}"; do
    CACHED=$(ls "$APT_CACHE"/${pkg}_*_arm64.deb 2>/dev/null | head -1)
    if [ -n "$CACHED" ]; then
        echo "  [CACHE HIT]  $pkg"
        continue
    fi

    echo "  [DOWNLOAD]   $pkg"
    # apt-get download fetches exactly one .deb, no dpkg involvement at all.
    # It outputs the file to the current directory, so we cd to the cache dir.
    (
        cd "$APT_CACHE"
        apt-get "${APT_OPTS[@]}" download "${pkg}:arm64"
    ) && echo "  [OK]         $pkg" || echo "  [WARN]       $pkg not found in repos (may already be in base image)"
done

echo ""
echo "Extracting packages into image filesystem..."
EXTRACTED=0
for deb in "$APT_CACHE"/*.deb; do
    [ -f "$deb" ] || { echo "  No .deb files in cache."; break; }
    echo "  Extracting: $(basename "$deb")"
    # dpkg-deb --extract = unzip the deb file tree into the mount point.
    # Runs at native x86 speed. No ARM64 code executes.
    dpkg-deb --extract "$deb" "$MOUNT_POINT"
    EXTRACTED=$((EXTRACTED + 1))
done
echo "  Total extracted: $EXTRACTED package(s)."

echo "Enabling NetworkManager service via symlink..."
SYSTEMD_WANTS="$MOUNT_POINT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$SYSTEMD_WANTS"

NM_SERVICE=""
for candidate in \
    "$MOUNT_POINT/lib/systemd/system/NetworkManager.service" \
    "$MOUNT_POINT/usr/lib/systemd/system/NetworkManager.service"; do
    [ -f "$candidate" ] && NM_SERVICE="$candidate" && break
done

if [ -n "$NM_SERVICE" ]; then
    NM_REL="${NM_SERVICE#$MOUNT_POINT}"
    ln -sf "$NM_REL" "$SYSTEMD_WANTS/NetworkManager.service"
    echo "  Enabled: NetworkManager.service -> $NM_REL"
else
    echo "  [WARN] NetworkManager.service not found in image."
    echo "         Run 'sudo systemctl enable NetworkManager' on first boot."
fi

echo "[OK] Dependencies step complete (no QEMU used)."