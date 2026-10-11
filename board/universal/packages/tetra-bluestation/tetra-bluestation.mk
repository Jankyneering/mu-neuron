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

# The cargo infra installs built binaries to /usr/bin; the muneuron status
# tool and device_table expect /usr/local/bin, so relocate after install.
define TETRA_BLUESTATION_INSTALL_TARGET_CMDS
	mv $(TARGET_DIR)/usr/bin/bluestation-bs \
		$(TARGET_DIR)/usr/local/bin/bluestation-bs
endef

$(eval $(cargo-package))
