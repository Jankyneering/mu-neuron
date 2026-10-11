#!/bin/bash
set -e

TARGET_DIR=$1   # Buildroot passes the target rootfs path as $1

# Figure out which git tree we are building from: post-build.sh is run from
# the Buildroot output directory, which may not be inside the repo (e.g. the
# Docker flow with a separate output volume). Walk up from the Buildroot
# configuration file (or from this script's copy in the output dir) to the
# tree root marked by external.desc, so the version is always taken from the
# real source tree, never from an unrelated or absent git directory.
TOPDIR="$(dirname "${BR2_CONFIG:-$0}")"
while [ -n "$TOPDIR" ] && [ "$TOPDIR" != "/" ] && [ ! -f "$TOPDIR/external.desc" ]; do
    TOPDIR="${TOPDIR%/*}"
done
if [ -z "$TOPDIR" ] || [ "$TOPDIR" = "/" ] || [ ! -f "$TOPDIR/external.desc" ]; then
    echo "ERROR: could not locate the µNeuron tree root (external.desc not found)" >&2
    exit 1
fi
REPO_DIR="$TOPDIR"

# Version: annotated tag if reachable, else short hash. MU_NEURON_VERSION in
# the environment overrides detection (for tarball/CI builds without git
# metadata). safe.directory is required for the Docker flow, where the repo
# is bind-mounted and git refuses it with "detected dubious ownership".
VERSION="${MU_NEURON_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null)" \
        || { echo "ERROR: could not run git describe in $REPO_DIR" >&2; exit 1; }
    if [ -z "$VERSION" ]; then
        echo "ERROR: git describe returned an empty version in $REPO_DIR" >&2
        exit 1
    fi
fi

cat > "${TARGET_DIR}/etc/os-release" <<EOF
NAME="µNeuron"
VERSION="${VERSION}"
ID=muneuron
PRETTY_NAME="µNeuron ${VERSION}"
VERSION_ID="${VERSION}"
EOF

echo ">>> Post-build script completed (version: ${VERSION})"
echo ">>> Note: Python packages (luma.oled, luma.core) are installed via buildroot BR2_PACKAGE_* options"
