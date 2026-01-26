#!/bin/bash
set -e

LOG_FILE="build.log"

print_step() {
    echo ""
    echo "========================================================"
    echo " STEP $1: $2"
    echo "========================================================"
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo " This script must be run as root. Try: sudo ./0_build_all.sh" 
   exit 1
fi

chmod +x 1_mount.sh 2_install_deps.sh 3_copy_agent.sh 4_shrink.sh

echo "Starting Build Process..." | tee $LOG_FILE

print_step "1" "MOUNTING IMAGE"
./1_mount.sh | tee -a $LOG_FILE

print_step "2" "INSTALLING DEPENDENCIES"
./2_install_deps.sh | tee -a $LOG_FILE

print_step "3" "INSTALLING AGENT"
./3_copy_agent.sh | tee -a $LOG_FILE

print_step "4" "CLEANUP & SHRINK"
./4_shrink.sh | tee -a $LOG_FILE

echo ""
echo "BUILD COMPLETE SUCCESSFULLY"