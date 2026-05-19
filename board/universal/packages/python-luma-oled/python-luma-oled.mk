# board/universal/packages/python-luma-oled/python-luma-oled.mk
PYTHON_LUMA_OLED_VERSION = 3.13.0
PYTHON_LUMA_OLED_SOURCE = luma.oled-$(PYTHON_LUMA_OLED_VERSION).tar.gz
PYTHON_LUMA_OLED_SITE = https://files.pythonhosted.org/packages/source/l/luma.oled
PYTHON_LUMA_OLED_SETUP_TYPE = setuptools
PYTHON_LUMA_OLED_LICENSE = MIT

$(eval $(python-package))
