#!/bin/sh
# Recompute the sha256 entries of a cargo package's generated download
# tarball (and its license files) into the package .hash file.
#
# Buildroot's cargo infra vendors all crate dependencies into a tarball at
# download time; its hash can only be computed AFTER that download has run,
# so the first build of a new version always fails the hash check. The
# tarball is left in dl/<pkg>/ though — this script hashes it and rewrites
# the .hash file. Run it after a failed build, then rebuild.
#
# Usage: refresh-cargo-hash.sh <package> [dl-dir]
set -e

PKG="${1:?usage: refresh-cargo-hash.sh <package> [dl-dir]}"
DL_DIR="${2:-dl}"
PKG_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)/board/universal/packages/$PKG"
HASH_FILE="$PKG_DIR/$PKG.hash"
MK_FILE="$PKG_DIR/$PKG.mk"
UPPER="$(echo "$PKG" | tr 'a-z-' 'A-Z_')"

if [ ! -f "$MK_FILE" ]; then
    echo "ERROR: no package mk at $MK_FILE" >&2
    exit 1
fi

TARBALL="$(ls -t "$DL_DIR/$PKG/$PKG-"*-cargo*.tar.gz 2>/dev/null | head -1)"
if [ -z "$TARBALL" ]; then
    echo "ERROR: no generated cargo tarball in $DL_DIR/$PKG/" >&2
    echo "       Run the build once first (the download must run to generate it)." >&2
    exit 1
fi

LICENSE_FILES="$(grep -m1 "^${UPPER}_LICENSE_FILES" "$MK_FILE" | cut -d'=' -f2 | tr -d ' "')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
    echo "# Locally computed by scripts/refresh-cargo-hash.sh"
    echo "# (regenerate after a version bump with: make refresh-cargo-hash)"
    printf 'sha256  %s  %s\n' \
        "$(sha256sum "$TARBALL" | cut -d' ' -f1)" \
        "$(basename "$TARBALL")"
    for lic in $LICENSE_FILES; do
        tar -xf "$TARBALL" -C "$TMP" --strip-components=1 --wildcards "*/$lic" 2>/dev/null \
            || continue
        printf 'sha256  %s  %s\n' \
            "$(sha256sum "$TMP/$lic" | cut -d' ' -f1)" \
            "$lic"
    done
} > "$HASH_FILE"

echo ">>> $HASH_FILE updated:"
cat "$HASH_FILE"
