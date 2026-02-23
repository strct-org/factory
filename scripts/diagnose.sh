#!/bin/bash
# =============================================================================
# diagnose.sh — inspect a built image or flashed SD card
#
# Designed for Armbian Orange Pi 3B (Rockchip RK3566) images.
#
# Partition layout:
#   p1 = FAT32 boot  — kernel, DTBs, extlinux/extlinux.conf, armbianEnv.txt
#   p2 = ext4 root   — full Debian rootfs
#   Raw sectors 64–16383 before p1 = U-Boot / idbloader (NOT a partition)
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

    IMGFILE="$TARGET"
    if [[ "$TARGET" == *.xz ]]; then
        echo "Decompressing $TARGET (this may take a minute)..."
        IMGFILE="${TARGET%.xz}"
        xz -dk "$TARGET"
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
    [ ! -b "$BOOT_DEV" ] && BOOT_DEV="${TARGET}s1"
    [ ! -b "$ROOT_DEV" ] && ROOT_DEV="${TARGET}s2"
fi

echo ""
echo "============================================================"
echo " Strct OS Image Diagnostics (Armbian / Orange Pi 3B / RK3566)"
echo " Boot partition: $BOOT_DEV  (FAT32, extlinux + DTBs)"
echo " Root partition: $ROOT_DEV  (ext4, Debian rootfs)"
echo " Note: U-Boot lives in raw sectors before p1 — not a partition"
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

# ── PARTUUIDs (informational only for RK3566) ─────────────────────────────────
echo ""
echo "--- PARTUUIDs (informational — U-Boot finds root by partition number) ---"
ACTUAL_ROOT_UUID=$(blkid -o value -s PARTUUID "$ROOT_DEV" 2>/dev/null || true)
ACTUAL_BOOT_UUID=$(blkid -o value -s PARTUUID "$BOOT_DEV" 2>/dev/null || true)
[ -n "$ACTUAL_ROOT_UUID" ] && ok "Root PARTUUID: $ACTUAL_ROOT_UUID" || warn "Root PARTUUID empty (normal for GPT or some MBR layouts)"
[ -n "$ACTUAL_BOOT_UUID" ] && ok "Boot PARTUUID: $ACTUAL_BOOT_UUID" || warn "Boot PARTUUID empty"

# ── Mount boot partition ──────────────────────────────────────────────────────
echo ""
echo "--- Boot partition (FAT32) ---"
TMP_BOOT=$(mktemp -d)
CLEANUP_MOUNTS+=("$TMP_BOOT")

mount "$BOOT_DEV" "$TMP_BOOT" 2>/dev/null || {
    fail "Cannot mount boot partition $BOOT_DEV"
    exit 1
}
ok "Boot partition mounted"

echo ""
echo "  Boot partition file listing:"
ls -lh "$TMP_BOOT/" | while IFS= read -r line; do info "$line"; done

# ── extlinux.conf check ───────────────────────────────────────────────────────
echo ""
echo "  extlinux check (Armbian/RK3566 boot method):"
if [ -f "$TMP_BOOT/extlinux/extlinux.conf" ]; then
    ok "extlinux/extlinux.conf found"
    echo ""
    info "extlinux.conf contents:"
    while IFS= read -r line; do info "  $line"; done < "$TMP_BOOT/extlinux/extlinux.conf"

    # Check for correct DTB
    DTB_LINE=$(grep -i "fdt\|dtb" "$TMP_BOOT/extlinux/extlinux.conf" || true)
    if echo "$DTB_LINE" | grep -qi "orangepi-3b\|rk3566-orangepi"; then
        ok "DTB references Orange Pi 3B ✓"
    elif [ -n "$DTB_LINE" ]; then
        warn "DTB line found but does not mention orangepi-3b — verify it is correct:"
        info "  $DTB_LINE"
    else
        warn "No FDT/DTB line found in extlinux.conf — U-Boot will use its compiled-in default"
    fi
else
    warn "extlinux/extlinux.conf not found"
    info "Expected at: ${TMP_BOOT}/extlinux/extlinux.conf"
    info "This may indicate the wrong base image was used (e.g. H618 instead of RK3566)"
fi

# ── armbianEnv.txt check ──────────────────────────────────────────────────────
echo ""
if [ -f "$TMP_BOOT/armbianEnv.txt" ]; then
    ok "armbianEnv.txt present"
    info "Contents:"
    while IFS= read -r line; do info "  $line"; done < "$TMP_BOOT/armbianEnv.txt"
else
    warn "armbianEnv.txt not found — overlays and verbosity settings use defaults"
fi

# cmdline.txt is a Raspberry Pi concept — explicitly confirm its absence is expected
if [ -f "$TMP_BOOT/cmdline.txt" ]; then
    warn "cmdline.txt found — unexpected for RK3566/Armbian (this is a Raspberry Pi file)"
else
    ok "cmdline.txt absent — correct for RK3566 U-Boot + extlinux boot"
fi

# ── DTB presence check ────────────────────────────────────────────────────────
echo ""
echo "  DTB files for Orange Pi 3B:"
DTB_FOUND=false
for dtb in \
    "$TMP_BOOT/dtb/rockchip/rk3566-orangepi-3b.dtb" \
    "$TMP_BOOT/dtb/rockchip/rk3566-orangepi-3b-v2.1.dtb" \
    "$TMP_BOOT/dtb/rk3566-orangepi-3b.dtb"; do
    if [ -f "$dtb" ]; then
        ok "Found: $dtb"
        DTB_FOUND=true
    fi
done
if [ "$DTB_FOUND" = "false" ]; then
    # List what DTBs are there so user can see
    if [ -d "$TMP_BOOT/dtb/rockchip" ]; then
        warn "No rk3566-orangepi-3b*.dtb found. Available Rockchip DTBs:"
        ls "$TMP_BOOT/dtb/rockchip/" | grep -i "rk3566\|orangepi" | while IFS= read -r f; do info "  $f"; done || true
    elif [ -d "$TMP_BOOT/dtb" ]; then
        warn "No rk3566-orangepi-3b*.dtb found. dtb/ contents:"
        ls "$TMP_BOOT/dtb/" | while IFS= read -r f; do info "  $f"; done
    else
        fail "No dtb/ directory found on boot partition — wrong base image?"
    fi
fi

umount "$TMP_BOOT"
CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$TMP_BOOT}")
rmdir "$TMP_BOOT"

# ── Mount root partition ──────────────────────────────────────────────────────
echo ""
echo "--- Root partition (ext4) ---"
TMP_ROOT=$(mktemp -d)
CLEANUP_MOUNTS+=("$TMP_ROOT")

mount "$ROOT_DEV" "$TMP_ROOT" 2>/dev/null || {
    fail "Cannot mount root partition $ROOT_DEV"
    exit 1
}
ok "Root partition mounted"

# Check fstab
echo ""
echo "  /etc/fstab:"
if [ -f "$TMP_ROOT/etc/fstab" ]; then
    while IFS= read -r line; do info "  $line"; done < "$TMP_ROOT/etc/fstab"
else
    warn "/etc/fstab not found"
fi

# Check agent binary
echo ""
echo "  Agent files:"
if [ -f "$TMP_ROOT/usr/local/bin/strct-agent" ]; then
    ok "strct-agent binary present"
    info "$(ls -lh "$TMP_ROOT/usr/local/bin/strct-agent")"
    FILETYPE=$(file "$TMP_ROOT/usr/local/bin/strct-agent")
    info "$FILETYPE"
    if echo "$FILETYPE" | grep -q "aarch64\|ARM aarch64"; then
        ok "Binary is ARM64 ✓"
    else
        fail "Binary is NOT ARM64 — will fail on Orange Pi 3B"
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

if [ -L "$TMP_ROOT/etc/systemd/system/multi-user.target.wants/strct-agent.service" ]; then
    ok "Service is enabled (symlink exists)"
else
    warn "Service may not be enabled — no symlink in multi-user.target.wants"
fi

# Check installed packages
echo ""
echo "  Key packages (from dpkg):"
for pkg in hostapd dnsmasq iw wpasupplicant iptables net-tools tailscale; do
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
echo ""
echo " Orange Pi 3B boot chain:"
echo "   1. ROM loads idbloader from raw sectors 64-16383"
echo "   2. idbloader loads U-Boot from sectors 16384+"
echo "   3. U-Boot reads extlinux/extlinux.conf from p1 (FAT32)"
echo "   4. extlinux.conf points U-Boot at kernel + DTB"
echo "   5. Kernel boots, mounts p2 as rootfs"
echo ""
echo " If it still shows black screen after fixing the base image:"
echo "   - Connect via SSH over ethernet to confirm the OS is actually running"
echo "   - Check dmesg | grep -i drm for display driver errors"
echo "   - The vendor kernel 6.1.x is required for stable HDMI on RK3566"
echo "============================================================"