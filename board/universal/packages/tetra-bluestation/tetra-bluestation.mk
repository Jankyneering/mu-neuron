################################################################################
#
# tetra-bluestation
#
# The upstream project publishes prebuilt bluestation-bs binaries per release.
# We install the aarch64 build (identical assets are published for rpi4/rpi5
# and generic aarch64; all targets in µNeuron are aarch64).
#
################################################################################

TETRA_BLUESTATION_VERSION = v0.5.10-09d4e0d
TETRA_BLUESTATION_SITE = https://github.com/MidnightBlueLabs/tetra-bluestation/releases/download/$(TETRA_BLUESTATION_VERSION)
TETRA_BLUESTATION_SOURCE = bluestation-bs-aarch64-generic
TETRA_BLUESTATION_LICENSE = PROPRIETARY (upstream prebuilt binary)

define TETRA_BLUESTATION_EXTRACT_CMDS
	cp $(TETRA_BLUESTATION_DL_DIR)/$(TETRA_BLUESTATION_SOURCE) $(@D)/bluestation-bs
endef

define TETRA_BLUESTATION_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bluestation-bs \
		$(TARGET_DIR)/usr/local/bin/bluestation-bs
endef

$(eval $(generic-package))
