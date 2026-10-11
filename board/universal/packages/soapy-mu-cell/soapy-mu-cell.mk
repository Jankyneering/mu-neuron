SOAPY_MU_CELL_VERSION     = v1.0.1
SOAPY_MU_CELL_SITE        = https://github.com/Jankyneering/mu-cell-bb-drivers
SOAPY_MU_CELL_SITE_METHOD = git
SOAPY_MU_CELL_GIT_SUBMODULES = NO
SOAPY_MU_CELL_SUBDIR      = SoapyMuCell
SOAPY_MU_CELL_LICENSE     = MIT
SOAPY_MU_CELL_LICENSE_FILES = LICENSE
SOAPY_MU_CELL_DEPENDENCIES = soapy-sdr openssl alsa-lib
SOAPY_MU_CELL_CONF_OPTS   = \
    -DINSTALL_PIPEWIRE_CONF=OFF \
    -DGIT_EXECUTABLE=/bin/false

SOAPY_MU_CELL_LINUX_GPIO_H = $(STAGING_DIR)/usr/include/linux/gpio.h
SOAPY_MU_CELL_LINUX_GPIO_H_URL = https://raw.githubusercontent.com/torvalds/linux/v5.15/include/uapi/linux/gpio.h

define SOAPY_MU_CELL_PATCH_KERNEL_HEADERS
	if ! grep -q gpio_v2_line_request $(SOAPY_MU_CELL_LINUX_GPIO_H) 2>/dev/null; then \
		echo ">>> soapy-mu-cell: patching gpio.h with kernel 5.15 GPIO v2 UAPI"; \
		curl -s $(SOAPY_MU_CELL_LINUX_GPIO_H_URL) -o $(SOAPY_MU_CELL_LINUX_GPIO_H); \
	fi
endef

SOAPY_MU_CELL_PRE_CONFIGURE_HOOKS += SOAPY_MU_CELL_PATCH_KERNEL_HEADERS

$(eval $(cmake-package))