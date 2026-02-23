#!/bin/bash
# =============================================================================
# diagnose.sh — inspect a built image or flashed SD card
#
# Usage (on the image file, before flashing):
#   sudo ./diagnose.sh --image ../strct-os-v1.0.3.img.xz
#   sudo ./diagnose.sh --image ../strct-release-v1.img
#
# Usage (on the SD card after flashing, card inserted in laptop):
#   sudo ./diagnose.sh --device /dev/sda    # Linux
#   sudo ./diagnose.sh --device /dev/disk4  # macOS
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail() { echo -e "${RED}[FAIL]${NC}  $1"; }
info() { echo -e "        $1"; }

CLEANUP_LOOP=""
CLEANUP_MOUNTS=()

cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    for mp in "${CLEANUP_MOUNTS[@]}"; do
        umount -lf "$mp" 2>/dev/null || true
    done
    if [ -n "$CLEANUP_LOOP" ]; then
        losetup -d "$CLEANUP_LOOP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Parse arguments ───────────────────────────────────────────────────────────
MODE=""
TARGET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --image)  MODE="image";  TARGET="$2"; shift 2 ;;
        --device) MODE="device"; TARGET="$2"; shift 2 ;;
        *) echo "Usage: $0 --image <file.img[.xz]> | --device <dev>"; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Usage: $0 --image <file.img[.xz]> | --device <dev>"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run as root: sudo $0 $*"
    exit 1
fi

# ── Set up access to the partitions ───────────────────────────────────────────
BOOT_DEV=""
ROOT_DEV=""

if [ "$MODE" = "image" ]; then
    if [ ! -f "$TARGET" ]; then
        fail "Image file not found: $TARGET"
        exit 1
    fi

    # Decompress if needed
    IMGFILE="$TARGET"
    if [[ "$TARGET" == *.xz ]]; then
        echo "Decompressing $TARGET (this may take a minute)..."
        IMGFILE="${TARGET%.xz}"
        xz -dk "$TARGET"   # -k = keep original, -d = decompress
    fi

    echo "Setting up loop device for $IMGFILE..."
    LOOP_DEV=$(losetup -fP --show "$IMGFILE")
    CLEANUP_LOOP="$LOOP_DEV"
    ok "Loop device: $LOOP_DEV"

    BOOT_DEV="${LOOP_DEV}p1"
    ROOT_DEV="${LOOP_DEV}p2"

elif [ "$MODE" = "device" ]; then
    if [ ! -b "$TARGET" ]; then
        fail "Not a block device: $TARGET"
        exit 1
    fi
    BOOT_DEV="${TARGET}1"
    ROOT_DEV="${TARGET}2"
    # On macOS partitions may be named differently
    [ ! -b "$BOOT_DEV" ] && BOOT_DEV="${TARGET}s1"
    [ ! -b "$ROOT_DEV" ] && ROOT_DEV="${TARGET}s2"
fi

echo ""
echo "============================================================"
echo " Strct OS Image Diagnostics"
echo " Boot partition: $BOOT_DEV"
echo " Root partition: $ROOT_DEV"
echo "============================================================"

# ── Check partitions exist ────────────────────────────────────────────────────
echo ""
echo "--- Partition check ---"
if [ -b "$BOOT_DEV" ]; then
    ok "Boot partition exists: $BOOT_DEV"
else
    fail "Boot partition NOT found: $BOOT_DEV"
    exit 1
fi
if [ -b "$ROOT_DEV" ]; then
    ok "Root partition exists: $ROOT_DEV"
else
    fail "Root partition NOT found: $ROOT_DEV"
    exit 1
fi

# ── Read PARTUUIDs from the actual partitions ─────────────────────────────────
echo ""
echo "--- PARTUUIDs (from blkid — this is the ground truth) ---"
ACTUAL_ROOT_UUID=$(blkid -o value -s PARTUUID "$ROOT_DEV")
ACTUAL_BOOT_UUID=$(blkid -o value -s PARTUUID "$BOOT_DEV")

if [ -n "$ACTUAL_ROOT_UUID" ]; then
    ok "Root PARTUUID: $ACTUAL_ROOT_UUID"
else
    fail "Root PARTUUID is EMPTY — blkid cannot read partition"
fi
if [ -n "$ACTUAL_BOOT_UUID" ]; then
    ok "Boot PARTUUID: $ACTUAL_BOOT_UUID"
else
    fail "Boot PARTUUID is EMPTY — blkid cannot read partition"
fi

# ── Mount boot partition and check cmdline.txt ───────────────────────────────
echo ""
echo "--- Boot partition contents ---"
TMP_BOOT=$(mktemp -d)
CLEANUP_MOUNTS+=("$TMP_BOOT")

mount "$BOOT_DEV" "$TMP_BOOT" 2>/dev/null || {
    fail "Cannot mount boot partition $BOOT_DEV"
    exit 1
}
ok "Boot partition mounted"

# Bookworm uses /boot/firmware, Bullseye uses /boot directly
CMDLINE=""
if [ -f "$TMP_BOOT/cmdline.txt" ]; then
    CMDLINE="$TMP_BOOT/cmdline.txt"
elif [ -f "$TMP_BOOT/firmware/cmdline.txt" ]; then
    CMDLINE="$TMP_BOOT/firmware/cmdline.txt"
fi

if [ -z "$CMDLINE" ]; then
    fail "cmdline.txt NOT FOUND in boot partition"
else
    ok "Found: $CMDLINE"
    echo ""
    info "cmdline.txt contents:"
    info "$(cat "$CMDLINE")"
    echo ""

    # Extract the root= value
    ROOT_ARG=$(grep -oP 'root=\S+' "$CMDLINE" || echo "")
    if [ -z "$ROOT_ARG" ]; then
        fail "No root= argument in cmdline.txt — Pi cannot find root partition"
    else
        info "root= argument: $ROOT_ARG"
        CMDLINE_UUID=$(echo "$ROOT_ARG" | grep -oP 'PARTUUID=\K\S+' || echo "")

        if [ -z "$CMDLINE_UUID" ]; then
            fail "root= does not use PARTUUID — unexpected format"
        elif [ "$CMDLINE_UUID" = "$ACTUAL_ROOT_UUID" ]; then
            ok "cmdline.txt PARTUUID matches actual partition ✓"
        else
            fail "PARTUUID MISMATCH:"
            fail "  cmdline.txt says: $CMDLINE_UUID"
            fail "  Actual partition: $ACTUAL_ROOT_UUID"
            fail "  This is why the Pi hangs at the logo!"
        fi
    fi
fi

# Check config.txt exists
if ls "$TMP_BOOT"/config.txt "$TMP_BOOT"/firmware/config.txt 2>/dev/null | head -1 | grep -q config; then
    ok "config.txt present"
else
    warn "config.txt not found — may affect boot"
fi

umount "$TMP_BOOT"
CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$TMP_BOOT}")
rmdir "$TMP_BOOT"

# ── Mount root partition and check fstab + agent files ───────────────────────
echo ""
echo "--- Root partition contents ---"
TMP_ROOT=$(mktemp -d)
CLEANUP_MOUNTS+=("$TMP_ROOT")

mount "$ROOT_DEV" "$TMP_ROOT" 2>/dev/null || {
    fail "Cannot mount root partition $ROOT_DEV"
    exit 1
}
ok "Root partition mounted"

# Check fstab
echo ""
echo "  fstab:"
if [ -f "$TMP_ROOT/etc/fstab" ]; then
    while IFS= read -r line; do
        info "  $line"
    done < "$TMP_ROOT/etc/fstab"

    # Verify fstab PARTUUIDs
    FSTAB_ROOT=$(grep -oP 'PARTUUID=\S+(?=\s+/\s)' "$TMP_ROOT/etc/fstab" || echo "")
    FSTAB_BOOT=$(grep -oP 'PARTUUID=\S+(?=\s+/boot)' "$TMP_ROOT/etc/fstab" || echo "")

    echo ""
    if [ "$FSTAB_ROOT" = "PARTUUID=$ACTUAL_ROOT_UUID" ]; then
        ok "fstab root PARTUUID matches"
    else
        fail "fstab root PARTUUID mismatch:"
        fail "  fstab:     $FSTAB_ROOT"
        fail "  Actual:    PARTUUID=$ACTUAL_ROOT_UUID"
    fi
    if [ "$FSTAB_BOOT" = "PARTUUID=$ACTUAL_BOOT_UUID" ]; then
        ok "fstab boot PARTUUID matches"
    else
        warn "fstab boot PARTUUID mismatch (may not affect boot):"
        warn "  fstab:     $FSTAB_BOOT"
        warn "  Actual:    PARTUUID=$ACTUAL_BOOT_UUID"
    fi
else
    fail "/etc/fstab not found on root partition"
fi

# Check agent binary
echo ""
echo "  Agent files:"
if [ -f "$TMP_ROOT/usr/local/bin/strct-agent" ]; then
    ok "strct-agent binary present"
    info "$(ls -lh "$TMP_ROOT/usr/local/bin/strct-agent")"
    # Check it's actually an ARM64 ELF
    FILETYPE=$(file "$TMP_ROOT/usr/local/bin/strct-agent")
    info "$FILETYPE"
    if echo "$FILETYPE" | grep -q "aarch64\|ARM aarch64"; then
        ok "Binary is ARM64 ✓"
    else
        fail "Binary is NOT ARM64 — will fail on Orange Pi"
        info "Expected: ELF 64-bit LSB executable, ARM aarch64"
    fi
else
    fail "strct-agent binary NOT found at /usr/local/bin/strct-agent"
fi

if [ -f "$TMP_ROOT/etc/strct/.env" ]; then
    ok ".env file present (not showing contents)"
else
    warn ".env not found at /etc/strct/.env"
fi

if [ -f "$TMP_ROOT/etc/strct/frpc" ]; then
    ok "frpc binary present"
else
    warn "frpc not found at /etc/strct/frpc"
fi

# Check systemd service
echo ""
echo "  Systemd service:"
if [ -f "$TMP_ROOT/etc/systemd/system/strct-agent.service" ]; then
    ok "strct-agent.service present"
    info "$(cat "$TMP_ROOT/etc/systemd/system/strct-agent.service")"
else
    fail "strct-agent.service NOT found"
fi

# Check service is enabled (symlink in multi-user.target.wants)
if [ -L "$TMP_ROOT/etc/systemd/system/multi-user.target.wants/strct-agent.service" ]; then
    ok "Service is enabled (symlink exists)"
else
    warn "Service may not be enabled — no symlink in multi-user.target.wants"
fi

# Check installed packages
echo ""
echo "  Key packages (from dpkg):"
for pkg in hostapd dnsmasq iw wpasupplicant iptables net-tools; do
    if chroot "$TMP_ROOT" dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        ok "$pkg installed"
    else
        warn "$pkg NOT installed"
    fi
done

umount "$TMP_ROOT"
CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$TMP_ROOT}")
rmdir "$TMP_ROOT"

echo ""
echo "============================================================"
echo " Diagnostics complete."
echo " If you see PARTUUID MISMATCH above — that is your boot bug."
echo " If PARTUUIDs match and it still hangs, connect a serial"
echo " console (UART pins on the Orange Pi) to see kernel messages."
echo "============================================================"