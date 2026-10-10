MU_CELL_BB_DTS_VERSION     = 6714e1b29cda643a53d8086789d41e9f99a80c9e
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

define MU_CELL_BB_DTS_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/boot/overlays
	$(INSTALL) -m 0644 $(@D)/mu-cell-bb_raspberrypi.dtbo \
		$(TARGET_DIR)/boot/overlays/mu-cell-bb_raspberrypi.dtbo
endef

$(eval $(generic-package))
