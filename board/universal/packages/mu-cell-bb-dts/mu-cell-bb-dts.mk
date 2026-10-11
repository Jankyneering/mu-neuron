MU_CELL_BB_DTS_VERSION     = v1.0.2
MU_CELL_BB_DTS_SITE        = https://github.com/Jankyneering/mu-cell-bb-drivers
MU_CELL_BB_DTS_SITE_METHOD = git
MU_CELL_BB_DTS_LICENSE     = MIT
MU_CELL_BB_DTS_LICENSE_FILES = LICENSE

MU_CELL_BB_DTS_HAT_TX_PIN ?= 22
MU_CELL_BB_DTS_HAT_RX_PIN ?= 23

define MU_CELL_BB_DTS_BUILD_CMDS
	gcc -E \
		-nostdinc -undef -x assembler-with-cpp \
		-DHAT_TX_PIN=$(MU_CELL_BB_DTS_HAT_TX_PIN) \
		-DHAT_RX_PIN=$(MU_CELL_BB_DTS_HAT_RX_PIN) \
		$(@D)/raspberry-pi-drivers/mu-cell-bb-dts/mu-cell-bb_raspberrypi.dts \
	| grep -v '^#' \
	| $(HOST_DIR)/bin/dtc \
		-Wno-unit_address_vs_reg \
		-I dts -O dtb \
		-o $(@D)/mu-cell-bb_raspberrypi.dtbo -
endef

# The overlay must reach the FAT boot partition, which is what the
# bootloader reads. /boot in the rootfs is a mount point for that FAT
# partition at runtime, so installing into TARGET_DIR/boot would be
# shadowed and never seen. Stage it where the per-board post-image
# script picks up boot files (BINARIES_DIR/rpi-firmware), like the
# upstream overlays shipped by the rpi-firmware package.
define MU_CELL_BB_DTS_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(BINARIES_DIR)/rpi-firmware/overlays
	$(INSTALL) -m 0644 $(@D)/mu-cell-bb_raspberrypi.dtbo \
		$(BINARIES_DIR)/rpi-firmware/overlays/mu-cell-bb_raspberrypi.dtbo
endef

$(eval $(generic-package))
