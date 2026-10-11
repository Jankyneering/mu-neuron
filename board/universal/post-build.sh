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

# Version: MU_NEURON_VERSION from the environment (set by the top-level
# Makefile, which resolves it on the host where git can see the submodule
# gitdir) or the .version stamp next to external.desc. Fall back to git
# in the tree for native builds.
VERSION="${MU_NEURON_VERSION:-}"
if [ -z "$VERSION" ] && [ -s "$REPO_DIR/.version" ]; then
    VERSION="$(cat "$REPO_DIR/.version")"
fi
if [ -z "$VERSION" ]; then
    # GIT_CONFIG_* forces the process-wide safe.directory (the -c option
    # only covers the top-level call, not whatever git discovers on its own).
    GIT_ERR="$(cd "$REPO_DIR" && GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=safe.directory \
        GIT_CONFIG_VALUE_0="$REPO_DIR" \
        git describe --tags --always --dirty 2>&1 >/dev/null)" || true
    VERSION="$(cd "$REPO_DIR" && GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=safe.directory \
        GIT_CONFIG_VALUE_0="$REPO_DIR" \
        git describe --tags --always --dirty 2>/dev/null)" || true
    if [ -z "$VERSION" ]; then
        echo "ERROR: could not determine the version in $REPO_DIR" >&2
        if [ -n "$GIT_ERR" ]; then
            echo "       git said: $GIT_ERR" >&2
        else
            echo "       git describe produced no output (no commits, no tags?)" >&2
        fi
        echo "       If this is a submodule inside a bind-mounted container and its" >&2
        echo "       .git dir lives outside the mount, git cannot see it. Copy the" >&2
        echo "       gitdir into the mount, or pass -e MU_NEURON_VERSION=<tag> to" >&2
        echo "       docker run to set the version explicitly." >&2
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
