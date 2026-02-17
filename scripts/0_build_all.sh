#!/bin/bash
set -euo pipefail

LOG_FILE="build.log"

print_step() {
    echo ""
    echo "========================================================"
    echo " STEP $1: $2"
    echo "========================================================"
}

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run as root. Try: sudo -E ./0_build_all.sh"
   exit 1
fi

chmod +x 1_mount.sh 2_install_deps.sh 3_copy_agent.sh 4_shrink.sh

echo "Starting Orange Pi Build Process..." | tee "$LOG_FILE"

print_step "0" "CHECKING HOST REQUIREMENTS"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq eatmydata parted qemu-user-static binfmt-support wget curl udev | tee -a "$LOG_FILE"

print_step "1" "MOUNTING AND EXPANDING IMAGE"
./1_mount.sh | tee -a "$LOG_FILE"

print_step "2" "INSTALLING DEPENDENCIES"
./2_install_deps.sh | tee -a "$LOG_FILE"

print_step "3" "INSTALLING AGENT & CONFIG"
./3_copy_agent.sh | tee -a "$LOG_FILE"

print_step "4" "CLEANUP AND FINALIZE"
./4_shrink.sh | tee -a "$LOG_FILE"

echo ""
echo "[SUCCESS] BUILD COMPLETE."
