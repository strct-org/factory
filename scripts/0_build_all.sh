#!/bin/bash
set -e
set -o pipefail

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

echo "Starting Factory Build Process..." | tee $LOG_FILE

print_step "0" "CHECKING HOST REQUIREMENTS"

# We no longer need qemu-user-static or binfmt-support —
# ARM64 packages are extracted natively on x86, no emulation.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    parted \
    dpkg-dev \
    wget \
    curl | tee -a $LOG_FILE

echo "[OK] Host environment is ready." | tee -a $LOG_FILE

print_step "1" "MOUNTING AND EXPANDING IMAGE"
./1_mount.sh | tee -a $LOG_FILE

print_step "2" "INSTALLING DEPENDENCIES (native deb extraction, no QEMU)"
./2_install_deps.sh | tee -a $LOG_FILE

print_step "3" "INSTALLING AGENT & CONFIG"
./3_copy_agent.sh | tee -a $LOG_FILE

print_step "4" "CLEANUP, SHRINK AND FINALIZE"
./4_shrink.sh | tee -a $LOG_FILE

echo ""
echo "[SUCCESS] BUILD COMPLETE."