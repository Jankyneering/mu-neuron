#!/bin/bash
set -e

TARGET=$1   # Buildroot passes the target rootfs path as $1

echo ">>> Post-build script completed"
echo ">>> Note: Python packages (luma.oled, luma.core) are installed via buildroot BR2_PACKAGE_* options"
