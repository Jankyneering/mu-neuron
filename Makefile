# =============================================================================
# µNeuron — Raspberry Pi SDR base-station image builder
# =============================================================================
# Priority target: Raspberry Pi 3 (BCM2710).
#   `make` builds a ready-to-flash Pi 3 image.
#   Other boards: `make TARGET=rpi4` / `make TARGET=rpi5`.
#   A multi-board "universal" image is still available: `make universal`.

TARGET ?= rpi3

BUILDROOT_DIR  ?= $(CURDIR)/buildroot
BOARD_DIR      := $(CURDIR)/board/universal
CUSTOM_DTS_DIR := $(BOARD_DIR)/custom-dts
OUTPUT_DIR     := $(CURDIR)/output
TARGET_OUTPUT := $(OUTPUT_DIR)/$(TARGET)
TARGET_IMAGE  := $(TARGET_OUTPUT)/images/sdcard.img
UNIVERSAL_BOOT := $(OUTPUT_DIR)/universal/boot
FINAL_IMAGE    := $(OUTPUT_DIR)/universal/sdcard.img

# One build per SoC family — a family image boots every board sharing that SoC:
#   rpi3: Pi 3B / 3B+ / Zero 2W / CM3   (BCM2710)
#   rpi4: Pi 4B / 400 / CM4 / CM4s     (BCM2711)
#   rpi5: Pi 5 / 500 / CM5             (BCM2712)
# To add a board to a family, add its DTB to DTBS_<family> below and to
# BR2_LINUX_KERNEL_INTREE_DTS_NAME in the family defconfig — nothing else.
TARGETS := rpi3 rpi4 rpi5

# Path to common config fragment applied to all targets
COMMON_FRAGMENT := $(BOARD_DIR)/config-fragments/common.config

# Your saved defconfigs (never overwritten)
DEFCONFIG_rpi3 := muneuron_rpi3_defconfig   # BCM2710, 64-bit
DEFCONFIG_rpi4 := muneuron_rpi4_defconfig   # BCM2711, 64-bit
DEFCONFIG_rpi5 := muneuron_rpi5_defconfig   # BCM2712, 64-bit

# Upstream Buildroot defconfigs — used ONCE for bootstrapping only
UPSTREAM_DEFCONFIG_rpi3 := raspberrypi3_64_defconfig
UPSTREAM_DEFCONFIG_rpi4 := raspberrypi4_64_defconfig
UPSTREAM_DEFCONFIG_rpi5 := raspberrypi5_defconfig

# DTBs to pull from each target's build output.
DTBS_rpi3   := bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb \
               bcm2710-rpi-zero-2-w.dtb bcm2710-rpi-cm3.dtb
DTBS_rpi4   := bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb \
               bcm2711-rpi-cm4.dtb bcm2711-rpi-cm4s.dtb
DTBS_rpi5   := bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-rpi-500.dtb \
               bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5l-cm5io.dtb

# Remote DTS details
REMOTE_DTS_URL := https://raw.githubusercontent.com/Jankyneering/mu-cell-bb-drivers/main/raspberry-pi-drivers/mu-cell-bb-dts/mu-cell-bb_raspberrypi.dts
REMOTE_DTS_NAME := mu-cell-bb_raspberrypi.dts
# This sentinel file tracks if we have the remote file
REMOTE_DTS_SENTINEL := $(CUSTOM_DTS_DIR)/.remote_dts_downloaded

# Per-board overlays (space-separated, without .dtbo extension)
OVERLAYS_rpi3 := miniuart-bt
OVERLAYS_rpi4 := miniuart-bt
OVERLAYS_rpi5 := miniuart-bt

# Custom overlays applied to ALL boards (e.g. a HAT present on every device)
OVERLAYS_COMMON := mu-cell-bb_raspberrypi

# Shared download cache — source tarballs downloaded once, reused across all targets.
# Mount as a separate Docker volume so clean-all never wipes it:
#   docker volume create rpi-buildroot-dl
#   docker run -v rpi-buildroot-dl:/work/dl ...
DL_DIR := $(CURDIR)/dl

# How many targets to build in parallel (for `make build-all`).
# 3 targets in parallel is safe with 128GB RAM on M4.
# Lower this if you want to leave headroom for other work.
PARALLEL_TARGETS := 3

# Kernel image name (64-bit unified)
KERNEL_IMAGE := Image

# Version stamp written by 'make version' on the host (where git can see the
# submodule gitdir). The Docker flow reads this file inside the container,
# where the bind-mounted submodule's .git target is unreachable.
VERSION_FILE := $(CURDIR)/.version

# DTC from the priority target's host tools (built by Buildroot)
DTC := $(OUTPUT_DIR)/rpi3/host/bin/dtc

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: all build build-all universal dtbs merge-boot final-image clean clean-all restage-boot-% \
        check-builds help

# Default: build the priority target (rpi3) and show its ready-to-flash image.
all: build
	@echo ""
	@echo ">>> Done: $(TARGET_IMAGE)"
	@echo ">>> Flash with:"
	@echo "    sudo dd if=$(TARGET_IMAGE) of=/dev/sdX bs=4M status=progress conv=fsync"

build: build-$(TARGET) restage-boot-$(TARGET)

# Full multi-board flow: build every SoC family, merge, assemble universal image.
universal: final-image

# =============================================================================
# Version stamp
# =============================================================================
# Write .version from git on the HOST. In the Docker flow the bind-mounted
# submodule's .git points outside the mount, so git inside the container
# cannot resolve it; the build reads this stamp instead.
version:
	@v="$${MU_NEURON_VERSION:-$$(git -C $(CURDIR) describe --tags --always --dirty 2>/dev/null)}"; \
	test -n "$$v" || { echo "ERROR: could not run git describe in $(CURDIR)"; exit 1; }; \
	echo "$$v" > $(VERSION_FILE); \
	echo ">>> $(VERSION_FILE): $$v"

.PHONY: version

# =============================================================================
# Update check
# =============================================================================
# Compare pinned third-party package versions against their upstream latest.
# No changes are made; this only reports what is available.
TETRA_BLUESTATION_MK := $(BOARD_DIR)/packages/tetra-bluestation/tetra-bluestation.mk
SOAPY_MU_CELL_MK := $(BOARD_DIR)/packages/soapy-mu-cell/soapy-mu-cell.mk
MU_CELL_BB_DTS_MK := $(BOARD_DIR)/packages/mu-cell-bb-dts/mu-cell-bb-dts.mk

check-updates:
	@echo ">>> Checking pinned package versions against upstream..."
	@current=$$(grep -m1 '^TETRA_BLUESTATION_VERSION' $(TETRA_BLUESTATION_MK) | cut -d' ' -f3); \
	latest=$$(curl -sfL -H 'Accept: application/vnd.github+json' \
		https://api.github.com/repos/MidnightBlueLabs/tetra-bluestation/releases/latest \
		| grep -m1 '"tag_name"' | cut -d'"' -f4); \
	if [ -z "$$latest" ]; then \
		echo "  tetra-bluestation: could not reach GitHub API"; \
	elif [ "$$current" = "$$latest" ]; then \
		echo "  tetra-bluestation: up-to-date ($$current)"; \
	else \
		echo "  tetra-bluestation: $$current -> available: $$latest"; \
		echo "    bump TETRA_BLUESTATION_VERSION in $(TETRA_BLUESTATION_MK)"; \
		echo "    and update the sha256 in tetra-bluestation.hash"; \
	fi
	@current=$$(grep -m1 '^SOAPY_MU_CELL_VERSION' $(SOAPY_MU_CELL_MK) | cut -d' ' -f3); \
	latest=$$(curl -sfL -H 'Accept: application/vnd.github+json' \
		https://api.github.com/repos/Jankyneering/mu-cell-bb-drivers/tags \
		| grep -m1 '"name"' | cut -d'"' -f4); \
	if [ -z "$$latest" ]; then \
		echo "  mu-cell-bb-drivers: could not reach GitHub API"; \
	elif [ "$$current" = "$$latest" ]; then \
		echo "  mu-cell-bb-drivers: up-to-date ($$current)"; \
	else \
		echo "  mu-cell-bb-drivers: $$current -> available: $$latest"; \
		echo "    bump SOAPY_MU_CELL_VERSION in $(SOAPY_MU_CELL_MK)"; \
		echo "    and MU_CELL_BB_DTS_VERSION in $(MU_CELL_BB_DTS_MK) (keep in sync)"; \
	fi

help:
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "  all              Build the priority target ($(TARGET)) — ready-to-flash sdcard.img"
	@echo "  build            Same as 'all'"
	@echo "  build-TARGET     Build one target        (e.g. make build-rpi4)"
	@echo "  build-all        Build all targets in parallel"
	@echo "  universal        Build everything + assemble the multi-board sdcard.img"
	@echo "  bootstrap-TARGET First-time config setup (e.g. make bootstrap-rpi4)"
	@echo "  dtbs             Copy and compile all DTBs (including custom)"
	@echo "  merge-boot       Merge boot partitions into universal/boot/"
	@echo "  final-image      Assemble the universal sdcard.img"
	@echo "  clean            Remove universal/ output only"
	@echo "  clean-all        Remove ALL build output (preserves dl/ cache)"
	@echo ""
	@echo "  Targets (one per SoC family):"
	@echo "    rpi3   Pi 3B / 3B+ / Zero 2W / CM3   (BCM2710)"
	@echo "    rpi4   Pi 4B / 400 / CM4 / CM4s     (BCM2711)"
	@echo "    rpi5   Pi 5 / 500 / CM5             (BCM2712)"
	@echo ""
	@echo "  Override with: make TARGET=<target>"
	@echo ""

# =============================================================================
# Bootstrap (first-time only)
# Loads upstream defconfig so you have a base to customize with menuconfig.
# After running this, do:
#   make -C buildroot O=output/<target> menuconfig
#   make -C buildroot O=output/<target> savedefconfig BR2_DEFCONFIG=configs/muneuron_<target>_defconfig
# =============================================================================
bootstrap-%:
	@if [ -z "$(filter $*,$(TARGETS))" ]; then \
	    echo "ERROR: unknown target '$*' (valid: $(TARGETS))"; exit 1; \
	fi
	@echo ">>> Bootstrapping $* from $(UPSTREAM_DEFCONFIG_$*)"
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    $(UPSTREAM_DEFCONFIG_$*)
	@echo ""
	@echo ">>> Next steps:"
	@echo "    make -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* menuconfig"
	@echo "    make -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* savedefconfig \\"
	@echo "         BR2_DEFCONFIG=$(CURDIR)/configs/$(DEFCONFIG_$*)"

# =============================================================================
# Build Buildroot per target
# Uses YOUR saved defconfig — never touches the upstream one.
# Sentinel file output/<target>/build.done tracks completion so
# build-all can skip already-finished targets.
# =============================================================================
build-%:
	@if [ -z "$(filter $*,$(TARGETS))" ]; then \
	    echo "ERROR: unknown target '$*' (valid: $(TARGETS))"; exit 1; \
	fi
	@if [ "$$(uname -s)" = "Darwin" ]; then \
	    echo "ERROR: native builds on macOS are not supported."; \
	    echo "       Buildroot needs GNU coreutils, genimage and a Linux host"; \
	    echo "       (merge_config.sh, image assembly, toolchain all assume it)."; \
	    echo "       Use the documented Docker flow instead:"; \
	    echo "         docker build -t rpi-buildroot ."; \
	    echo "         docker run --rm -it -v $$(pwd):/work -w /work rpi-buildroot make"; \
	    exit 1; \
	fi
	@echo ">>> Configuring $* from configs/$(DEFCONFIG_$*)"
	# Cloud-storage bind mounts (Nextcloud/iCloud on macOS) can lose the execute
	# bit inside the container, which breaks Buildroot's direct execution of the
	# post-build hook ("bad interpreter: Permission denied"). Copy the script
	# into the build output dir (a real volume) and point Buildroot at that copy.
	@mkdir -p $(OUTPUT_DIR)/$*
	@cp $(BOARD_DIR)/post-build.sh $(OUTPUT_DIR)/$*/post-build.sh
	@chmod +x $(OUTPUT_DIR)/$*/post-build.sh
	@if [ ! -f $(CURDIR)/configs/$(DEFCONFIG_$*) ]; then \
	    echo "ERROR: configs/$(DEFCONFIG_$*) not found."; \
	    echo "       Run 'make bootstrap-$*' first."; \
	    exit 1; \
	fi
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    BR2_EXTERNAL=$(CURDIR) \
	    BR2_DEFCONFIG=$(CURDIR)/configs/$(DEFCONFIG_$*) \
	    defconfig
	@echo ">>> Merging common fragment"
	$(BUILDROOT_DIR)/support/kconfig/merge_config.sh \
	    -m -O $(OUTPUT_DIR)/$* \
	    $(OUTPUT_DIR)/$*/.config \
	    $(COMMON_FRAGMENT)
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    olddefconfig
	@echo ">>> Building $*"
	v="$${MU_NEURON_VERSION:-}"; \
	if [ -z "$$v" ] && [ -s $(VERSION_FILE) ]; then v=$$(cat $(VERSION_FILE)); fi; \
	if [ -z "$$v" ]; then v=$$(git -C $(CURDIR) describe --tags --always --dirty 2>/dev/null || true); fi; \
	test -n "$$v" || { echo "ERROR: could not determine the muNeuron version."; \
	                   echo "       Run 'make version' on the host (outside Docker), or"; \
	                   echo "       pass -e MU_NEURON_VERSION=<tag> to docker run."; exit 1; }; \
	echo ">>> Building $* as muNeuron $$v"; \
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    BR2_DL_DIR=$(DL_DIR) \
	    MU_NEURON_VERSION="$$v" \
	    all
	@touch $(OUTPUT_DIR)/$*/build.done

# Restage boot-partition inputs that Buildroot does not track: the
# rpi-firmware package stamps are not invalidated when the *contents* of
# config.txt change, so an incremental build would ship a stale FAT
# partition. Always copy the current file into the images dir before the
# image is (re)assembled.
restage-boot-%:
	@if [ -z "$(filter $*,$(TARGETS))" ]; then \
	    echo "ERROR: unknown target '$*' (valid: $(TARGETS))"; exit 1; \
	fi
	@if [ -d $(OUTPUT_DIR)/$*/images/rpi-firmware ]; then \
	    cp $(BOARD_DIR)/config.txt $(OUTPUT_DIR)/$*/images/rpi-firmware/config.txt; \
	    cp $(BOARD_DIR)/bluestation-bs/config.toml $(OUTPUT_DIR)/$*/images/config.toml; \
	    echo ">>> Restaged config.txt and config.toml for $*"; \
	    echo ">>> Regenerating $* disk image (target-post-image)"; \
	    $(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* BR2_EXTERNAL=$(CURDIR) \
	        BR2_DL_DIR=$(DL_DIR) target-post-image || exit 1; \
	    grep -q "i2c-gpio" $(OUTPUT_DIR)/$*/images/rpi-firmware/config.txt \
	        || { echo "ERROR: restaged config.txt missing i2c-gpio"; exit 1; }; \
	    grep -q "config_version" $(OUTPUT_DIR)/$*/images/config.toml \
	        || { echo "ERROR: restaged config.toml missing config_version"; exit 1; }; \
	else \
	    echo "WARNING: no images/rpi-firmware for $*, skipping restage"; \
	fi

# Build all targets in parallel.
# Each Buildroot build internally uses all CPU cores, so we use a semaphore
# via a temp dir to limit to PARALLEL_TARGETS simultaneous builds.
# Logs for each target go to output/<target>/build.log for easy debugging.
build-all:
	@echo ">>> Building $(words $(TARGETS)) targets, $(PARALLEL_TARGETS) in parallel"
	@mkdir -p $(addprefix $(OUTPUT_DIR)/,$(TARGETS))
	@pids=""; \
	for target in $(TARGETS); do \
	    if [ -f $(OUTPUT_DIR)/$$target/build.done ]; then \
	        echo "=== Skipping $$target (already built) ==="; \
	        continue; \
	    fi; \
	    echo "=== Starting $$target ==="; \
	    $(MAKE) build-$$target \
	        > $(OUTPUT_DIR)/$$target/build.log 2>&1 & \
	    pids="$$pids $$!"; \
	done; \
	failed=0; \
	for pid in $$pids; do \
	    wait $$pid || failed=1; \
	done; \
	if [ $$failed -ne 0 ]; then \
	    echo ""; \
	    echo "ERROR: One or more builds failed. Check logs:"; \
	    for target in $(TARGETS); do \
	        if [ ! -f $(OUTPUT_DIR)/$$target/build.done ]; then \
	            echo "  tail -f $(OUTPUT_DIR)/$$target/build.log"; \
	        fi; \
	    done; \
	    exit 1; \
	fi
	@echo ">>> All targets built successfully"

# =============================================================================
# Verify all builds completed before merging
# =============================================================================
check-builds:
	@echo ">>> Checking all builds completed..."
	@all_ok=1; \
	for target in $(TARGETS); do \
	    rootfs=$$(find $(OUTPUT_DIR)/$$target/images -maxdepth 1 -name "rootfs.ext*" 2>/dev/null | head -1); \
	    if [ -n "$$rootfs" ] && [ -s "$$rootfs" ]; then \
	        echo "  OK:      $$target ($$rootfs)"; \
	    else \
	        echo "  MISSING: $$target (run 'make build-$$target')"; \
	        all_ok=0; \
	    fi; \
	done; \
	if [ $$all_ok -eq 0 ]; then exit 1; fi

# =============================================================================
# DTB handling
# =============================================================================

# Download the remote DTS if the sentinel file doesn't exist
fetch-remote-dts:
	@mkdir -p $(CUSTOM_DTS_DIR)
	@if [ ! -f $(REMOTE_DTS_SENTINEL) ]; then \
		echo ">>> Fetching remote DTS from GitHub..."; \
		curl -L $(REMOTE_DTS_URL) -o $(CUSTOM_DTS_DIR)/$(REMOTE_DTS_NAME); \
		if [ $$? -eq 0 ]; then \
			touch $(REMOTE_DTS_SENTINEL); \
			echo ">>> Remote DTS downloaded successfully."; \
		else \
			echo "ERROR: Failed to download remote DTS."; \
			exit 1; \
		fi; \
	else \
		echo ">>> Remote DTS is already up to date."; \
	fi


# Copy upstream DTBs from each target's build output into boot/.
# DTBs are copied to the root of the boot partition — the RPi bootloader
# finds them there automatically based on the board model.
# We search both images/ and images/rpi-firmware/ since Buildroot versions differ.
dtbs-%:
	@echo ">>> Copying upstream DTBs for $*"
	@mkdir -p $(UNIVERSAL_BOOT)/overlays
	@for dtb in $(DTBS_$*); do \
	    src=$$(find $(OUTPUT_DIR)/$*/images -name "$$dtb" 2>/dev/null | head -1); \
	    if [ -n "$$src" ] && [ -f "$$src" ]; then \
	        echo "    $$dtb"; \
	        cp "$$src" $(UNIVERSAL_BOOT)/$$dtb; \
	    else \
	        echo "    WARNING: $$dtb not found in output/$*/images/ — skipping"; \
	    fi; \
	done

# Compile custom .dts / .dtso files from board/universal/custom-dts/
#
# To add a custom device:
#   1. Drop your .dts or .dtso into board/universal/custom-dts/
#   2. Add the overlay name (without extension) to OVERLAYS_COMMON
#      or OVERLAYS_<target> for board-specific ones
#   3. Reference it in board/universal/config.txt with dtoverlay=<name>
#   4. Run: make dtbs merge-boot final-image
#
# .dts  -> .dtb   standalone device tree
# .dtso -> .dtbo  overlay, patched on top of base DT at boot
custom-dtbs-%: fetch-remote-dts
	@echo ">>> Compiling custom DTBs/overlays for $*"
	@mkdir -p $(UNIVERSAL_BOOT)/overlays
	@if [ ! -f $(DTC) ]; then \
	    echo "WARNING: dtc not found at $(DTC) — skipping custom DTBs."; \
	    echo "         Run 'make build-rpi3' first to build host tools."; \
	else \
	    for src in $(wildcard $(CUSTOM_DTS_DIR)/*.dts); do \
	        name=$$(basename $$src .dts); \
	        out=$(UNIVERSAL_BOOT)/$$name.dtb; \
	        echo "    $$name.dts -> $$name.dtb"; \
	        $(DTC) -I dts -O dtb -o $$out $$src; \
	    done; \
	    for src in $(wildcard $(CUSTOM_DTS_DIR)/*.dtso); do \
	        name=$$(basename $$src .dtso); \
	        out=$(UNIVERSAL_BOOT)/overlays/$$name.dtbo; \
	        echo "    $$name.dtso -> overlays/$$name.dtbo"; \
	        $(DTC) -I dts -O dtb -@ -o $$out $$src; \
	    done; \
	fi

dtbs: build-all check-builds $(addprefix dtbs-,$(TARGETS)) $(addprefix custom-dtbs-,$(TARGETS))

# =============================================================================
# Merge boot partitions
# =============================================================================
merge-boot: build-all check-builds dtbs
	@echo ">>> Merging firmware and kernel files"
	@mkdir -p $(UNIVERSAL_BOOT)/overlays

	# --- Firmware ---
	# Pi 3 / Zero 2W (BCM2710): needs start.elf + fixup.dat
	# Pi 4 / CM4    (BCM2711): needs start4.elf + fixup4.dat
	# Pi 5 / CM5    (BCM2712): uses SPI EEPROM — no .elf needed
	@for f in start.elf fixup.dat; do \
	    src=$$(find $(OUTPUT_DIR)/rpi3/images -name "$$f" 2>/dev/null | head -1); \
	    if [ -n "$$src" ] && [ -f "$$src" ]; then \
	        echo "    $$f (from $$src)"; \
	        cp "$$src" $(UNIVERSAL_BOOT)/; \
	    else \
	        echo "    WARNING: $$f not found — Pi 3/Zero2W may not boot without it"; \
	    fi; \
	done
	@for f in start4.elf fixup4.dat; do \
	    src=$$(find $(OUTPUT_DIR)/rpi4/images -name "$$f" 2>/dev/null | head -1); \
	    if [ -n "$$src" ] && [ -f "$$src" ]; then \
	        echo "    $$f (from $$src)"; \
	        cp "$$src" $(UNIVERSAL_BOOT)/; \
	    else \
	        echo "    WARNING: $$f not found — Pi 4/CM4 may not boot without it"; \
	    fi; \
	done

	# --- Kernels ---
	# BCM2710 (rpi3/zero2w) and BCM2711 (rpi4/cm4) can share a kernel.
	# BCM2712 (rpi5/cm5) needs its own — different SoC.
	@for target_dest in "rpi3:kernel-rpi3.img" "rpi4:kernel-rpi4.img" "rpi5:kernel-rpi5.img"; do \
	    target=$$(echo $$target_dest | cut -d: -f1); \
	    dest=$$(echo $$target_dest | cut -d: -f2); \
	    src=$(OUTPUT_DIR)/$$target/images/$(KERNEL_IMAGE); \
	    if [ -f $$src ]; then \
	        echo "    $$dest (from $$target)"; \
	        cp $$src $(UNIVERSAL_BOOT)/$$dest; \
	    else \
	        echo "ERROR: kernel not found at $$src"; exit 1; \
	    fi; \
	done

	# --- Overlays ---
	# Merge from all targets; -n means existing files are not overwritten,
	# so earlier targets take precedence in case of conflicts.
	@for target in $(TARGETS); do \
	    for candidate in \
	        $(OUTPUT_DIR)/$$target/images/rpi-firmware/overlays \
	        $(OUTPUT_DIR)/$$target/images/overlays; \
	    do \
	        if [ -d $$candidate ]; then \
	            echo "    Merging overlays from $$target"; \
	            cp -n $$candidate/*.dtbo $(UNIVERSAL_BOOT)/overlays/ 2>/dev/null || true; \
	            break; \
	        fi; \
	    done; \
	done

	# --- Board config files ---
	@if [ ! -f $(BOARD_DIR)/config.txt ]; then \
	    echo "ERROR: $(BOARD_DIR)/config.txt not found"; exit 1; \
	fi
	@if [ ! -f $(BOARD_DIR)/cmdline.txt ]; then \
	    echo "ERROR: $(BOARD_DIR)/cmdline.txt not found"; exit 1; \
	fi
	cp $(BOARD_DIR)/config.txt  $(UNIVERSAL_BOOT)/
	cp $(BOARD_DIR)/cmdline.txt $(UNIVERSAL_BOOT)/
	cp $(BOARD_DIR)/bluestation-bs/config.toml $(UNIVERSAL_BOOT)/

	@echo ""
	@echo ">>> Boot partition contents:"
	@find $(UNIVERSAL_BOOT) -type f | sort

# =============================================================================
# Final image assembly
# =============================================================================
# Uses genimage to produce a partitioned sdcard.img.
# genimage.cfg must define a FAT boot partition + ext4 rootfs partition.
# We use the priority target's rootfs as the shared userspace (all targets
# are built identically apart from the kernel/DTB set).
GENIMAGE     := genimage
GENIMAGE_CFG := $(BOARD_DIR)/genimage.cfg
ROOTFS       := $(OUTPUT_DIR)/rpi3/images/rootfs.ext2  # ext4 is a symlink to this

final-image: merge-boot
	@echo ">>> Assembling final sdcard.img"
	@if [ ! -f $(GENIMAGE_CFG) ]; then \
	    echo "ERROR: $(GENIMAGE_CFG) not found"; exit 1; \
	fi
	@if [ ! -f $(ROOTFS) ] && [ ! -L $(ROOTFS) ]; then \
	    echo "ERROR: rootfs not found at $(ROOTFS)"; exit 1; \
	fi
	@echo "    rootfs.ext4: $$(du -sh $(ROOTFS) | cut -f1)"
	# Copy Buildroot's pre-built rootfs.ext4 into inputpath alongside boot files
	# genimage will find it there when assembling sdcard.img
	@cp -L $(ROOTFS) $(UNIVERSAL_BOOT)/rootfs.ext4
	# Use an empty rootpath — we don't want genimage to regenerate rootfs
	@mkdir -p /tmp/genimage-empty
	@rm -rf $(OUTPUT_DIR)/universal/tmp && mkdir -p $(OUTPUT_DIR)/universal/tmp
	$(GENIMAGE) \
	    --config     $(GENIMAGE_CFG) \
	    --rootpath   /tmp/genimage-empty \
	    --tmppath    $(OUTPUT_DIR)/universal/tmp \
	    --inputpath  $(UNIVERSAL_BOOT) \
	    --outputpath $(OUTPUT_DIR)/universal
	# Verify the assembled image looks right
	@echo ""
	@echo ">>> Image partition layout:"
	@sgdisk -p $(OUTPUT_DIR)/universal/sdcard.img 2>/dev/null || \
	    fdisk -l $(OUTPUT_DIR)/universal/sdcard.img 2>/dev/null || true
	@echo ""
	@echo ">>> Done: $(FINAL_IMAGE)"
	@echo ">>> Flash with:"
	@echo "    sudo dd if=$(FINAL_IMAGE) of=/dev/sdX bs=4M status=progress conv=fsync"

# =============================================================================
# Copy final images to host
# =============================================================================
# Copy all per-target images and the final universal image to /work (Mac-visible)
# Run after a successful build:
#   docker run ... rpi-buildroot make copy-images
copy-images:
	@echo ">>> Copying final image to host..."
	@mkdir -p $(CURDIR)/images
	cp $(OUTPUT_DIR)/universal/sdcard.img $(CURDIR)/images/sdcard.img
	@echo ">>> Copying per-target images to host..."
	@for target in $(TARGETS); do \
	    mkdir -p $(CURDIR)/images/$$target; \
	    for f in \
	        $(OUTPUT_DIR)/$$target/images/rootfs.ext4 \
	        $(OUTPUT_DIR)/$$target/images/sdcard.img \
	        $(OUTPUT_DIR)/$$target/images/$(KERNEL_IMAGE); \
	    do \
	        if [ -f $$f ]; then \
	            echo "    $$target/$$(basename $$f)"; \
	            cp $$f $(CURDIR)/images/$$target/; \
	        fi; \
	    done; \
	done
	@echo ""
	@echo ">>> Done. Images available at:"
	@find $(CURDIR)/images -type f | sort


# =============================================================================
# Clean
# =============================================================================
clean:
	rm -rf $(OUTPUT_DIR)/universal
	@echo "Per-target build outputs preserved."
	@echo "To force a single target to rebuild: rm output/<target>/build.done"
	@echo "To clean one target's build:         make -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/<target> clean"

clean-all:
	rm -rf $(OUTPUT_DIR)
	@echo "All build outputs removed. Download cache in dl/ preserved."
	@echo "To also wipe the download cache:"
	@echo "  docker volume rm rpi-buildroot-dl && docker volume create rpi-buildroot-dl"
	