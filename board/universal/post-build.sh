#!/bin/bash
set -e

TARGET=$1   # Buildroot passes the target rootfs path as $1

# Try annotated tag first, fallback to short hash
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo [unknown])"

cat > "${TARGET_DIR}/etc/os-release" <<EOF
NAME="µNeuron"
VERSION="${VERSION}"
ID=muneuron
PRETTY_NAME="µNeuron ${VERSION}"
VERSION_ID="${VERSION}"
EOF

echo ">>> Post-build script completed"
echo ">>> Note: Python packages (luma.oled, luma.core) are installed via buildroot BR2_PACKAGE_* options"
