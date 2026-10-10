#!/bin/bash
# post-image for µNeuron per-board builds.
#
# Replaces upstream board/raspberrypi/post-image.sh, which extracts the
# kernel name with `sed -n 's/^kernel=//p' config.txt` — that matches every
# kernel= line, and µNeuron's multi-section config.txt ([all], [pi3],
# [pi4], [pi5]) has four of them, producing a multi-line value that breaks
# the template substitution (sed: unterminated `s' command). This script
# takes the kernel= from the [all] section only and stages the FAT files
# the same way, then runs genimage.

set -e

GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"

# Files for the FAT partition: DTBs at the root, rpi-firmware contents,
# the kernel from the [all] section of the current config.txt, and the
# bluestation-bs config.toml.
# The config.toml is user-editable on the FAT partition; keep a pristine copy
# in the board directory so rebuilds always stage the tracked version.
# This script runs from the Buildroot output directory (or has BR2_CONFIG set),
# so walk up to the tree root marked by external.desc.
TOPDIR="$(dirname "${BR2_CONFIG:-$0}")"
while [ -n "$TOPDIR" ] && [ "$TOPDIR" != "/" ] && [ ! -f "$TOPDIR/external.desc" ]; do
    TOPDIR="${TOPDIR%/*}"
done
if [ -n "$TOPDIR" ] && [ "$TOPDIR" != "/" ] && [ -f "$TOPDIR/board/universal/bluestation-bs/config.toml" ]; then
    cp "$TOPDIR/board/universal/bluestation-bs/config.toml" "${BINARIES_DIR}/config.toml"
else
    echo "WARNING: could not stage config.toml from the µNeuron tree root" >&2
fi
FILES=()
for i in "${BINARIES_DIR}"/*.dtb "${BINARIES_DIR}"/rpi-firmware/*; do
	FILES+=( "${i#${BINARIES_DIR}/}" )
done

KERNEL=$(sed -n '/^\[all\]/,/^\[pi/{s/^kernel=//p}' "${BINARIES_DIR}/rpi-firmware/config.txt" | head -1)
if [ -z "${KERNEL}" ]; then
	echo "ERROR: no kernel= line found in the [all] section of config.txt" >&2
	exit 1
fi
FILES+=( "${KERNEL}" )

if [ -f "${BINARIES_DIR}/config.toml" ]; then
	FILES+=( "config.toml" )
else
	echo "WARNING: no config.toml staged for the FAT partition (bluestation-bs will have no config)" >&2
fi

# The [piN] kernel= overrides in config.txt select per-family kernels in the
# universal multi-board image. This per-board image ships a single kernel
# under the [all] name, so drop those overrides from the FAT copy — the
# bootloader would otherwise look for kernel-rpi<N>.img and fail to boot.
sed -i -e '/^kernel=kernel-rpi[0-9]*\.img$/d' "${BINARIES_DIR}/rpi-firmware/config.txt"

BOOT_FILES=$(printf '\t\t\t"%s",\n' "${FILES[@]}")

cat > "${GENIMAGE_CFG}" <<EOF
image boot.vfat {
	vfat {
		files = {
${BOOT_FILES}
		}
	}

	size = 32M
}

image sdcard.img {
	hdimage {
	}

	partition boot {
		partition-type = 0xC
		bootable = "true"
		image = "boot.vfat"
	}

	partition rootfs {
		partition-type = 0x83
		image = "rootfs.ext4"
	}
}
EOF

# Pass an empty rootpath: genimage makes a full copy of the given rootpath,
# so passing TARGET_DIR would waste time and disk space. We only insert the
# pre-built rootfs image into the disk image.

trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"

rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}" \
	--tmppath "${GENIMAGE_TMP}" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"

exit $?
