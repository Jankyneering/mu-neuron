# board/universal/packages/python-luma-core/python-luma-core.mk
PYTHON_LUMA_CORE_VERSION = 2.4.2
PYTHON_LUMA_CORE_SOURCE = luma.core-$(PYTHON_LUMA_CORE_VERSION).tar.gz
PYTHON_LUMA_CORE_SITE = https://files.pythonhosted.org/packages/source/l/luma.core
PYTHON_LUMA_CORE_SETUP_TYPE = setuptools
PYTHON_LUMA_CORE_LICENSE = MIT

$(eval $(python-package))
