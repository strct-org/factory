#!/bin/bash
set -e

MOUNT_POINT="mnt_root"
APT_CACHE="../apt-cache"

# Packages to install into the image.
# Docker removed — the agent binary does not use it.
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

echo "Setting up isolated apt environment for ARM64 downloads..."

# Isolated temp dir so we don't touch the host's apt state at all
TMP_APT=$(mktemp -d)
trap "rm -rf $TMP_APT" EXIT

mkdir -p "$TMP_APT/etc/apt/trusted.gpg.d"
mkdir -p "$TMP_APT/var/lib/apt/lists"
mkdir -p "$TMP_APT/var/cache/apt/archives/partial"

cat > "$TMP_APT/etc/apt/sources.list" << EOF
deb [arch=arm64] http://deb.debian.org/debian bookworm main contrib non-free
deb [arch=arm64] http://deb.debian.org/debian-security bookworm-security main
deb [arch=arm64] http://deb.debian.org/debian bookworm-updates main
EOF

# Copy Debian archive keyring from host (GitHub runners have it)
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    cp /usr/share/keyrings/debian-archive-keyring.gpg \
        "$TMP_APT/etc/apt/trusted.gpg.d/"
else
    echo "Debian keyring not found on host, installing it..."
    apt-get install -y -qq debian-archive-keyring
    cp /usr/share/keyrings/debian-archive-keyring.gpg \
        "$TMP_APT/etc/apt/trusted.gpg.d/"
fi

# Common apt options pointing at our isolated environment
APT_OPTS=(
    -o Dir="$TMP_APT"
    -o Dir::Etc::SourceList="$TMP_APT/etc/apt/sources.list"
    -o Dir::Etc::SourceParts="/dev/null"
    -o Dir::Etc::Trusted="$TMP_APT/etc/apt/trusted.gpg.d"
    -o Dir::Cache="$TMP_APT/var/cache/apt"
    -o Dir::State="$TMP_APT/var/lib/apt"
    -o APT::Architecture="arm64"
    -o APT::Architectures="arm64"
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
    # --download-only fetches the package and all its dependencies
    apt-get "${APT_OPTS[@]}" \
        -o Dir::Cache::Archives="$TMP_APT/var/cache/apt/archives" \
        --download-only --yes install "$pkg" || {
        echo "  [WARN] Could not download $pkg"
        continue
    }

    # Move all newly downloaded debs to persistent cache
    find "$TMP_APT/var/cache/apt/archives" -maxdepth 1 -name "*.deb" \
        | while read deb; do
            dest="$APT_CACHE/$(basename "$deb")"
            [ -f "$dest" ] || mv "$deb" "$APT_CACHE/"
        done
done

echo "Extracting packages into image filesystem..."
EXTRACTED=0
# Extract everything in the cache — includes dependencies pulled in above
for deb in "$APT_CACHE"/*.deb; do
    [ -f "$deb" ] || continue
    echo "  Extracting: $(basename $deb)"
    dpkg-deb --extract "$deb" "$MOUNT_POINT"
    EXTRACTED=$((EXTRACTED + 1))
done
echo "  Extracted $EXTRACTED package(s)."

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
    echo "  NetworkManager.service enabled (-> $NM_REL)"
else
    echo "  [WARN] NetworkManager.service not found — enable on first boot with:"
    echo "         sudo systemctl enable NetworkManager"
fi

echo "[OK] Dependencies installed natively (no QEMU used)."