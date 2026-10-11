################################################################################
#
# tetra-bluestation
#
# Built from source with Buildroot's cargo infrastructure so the binary is
# linked against the image's own SoapySDR and glibc (the prebuilt upstream
# asset was built against unknown libraries). Dependencies are vendored into
# the download tarball by the cargo download post-process, so the build does
# not need network access after download.
#
################################################################################

TETRA_BLUESTATION_VERSION = 02286ef
TETRA_BLUESTATION_SITE = https://github.com/MidnightBlueLabs/tetra-bluestation
TETRA_BLUESTATION_SITE_METHOD = git
TETRA_BLUESTATION_LICENSE = MIT
TETRA_BLUESTATION_LICENSE_FILES = LICENSE

# rust-soapysdr locates libSoapySDR via pkg-config at build time.
TETRA_BLUESTATION_DEPENDENCIES = soapy-sdr host-pkgconf

# Upstream is a Cargo workspace; the root manifest is virtual (no [[bin]]).
# Build and install the bluestation-bs member crate, not the workspace root.
TETRA_BLUESTATION_SUBDIR = bins/bluestation-bs

# The cargo infra installs the binary to /usr/bin via `cargo install`.
# The muneuron status tool and device_table expect /usr/local/bin, so
# relocate it after the default target install step.
define TETRA_BLUESTATION_MOVE_TO_LOCAL_BIN
	mv $(TARGET_DIR)/usr/bin/bluestation-bs \
		$(TARGET_DIR)/usr/local/bin/bluestation-bs
endef
TETRA_BLUESTATION_POST_INSTALL_TARGET_HOOKS += TETRA_BLUESTATION_MOVE_TO_LOCAL_BIN

$(eval $(cargo-package))
