# =============================================================================
# Universal Raspberry Pi Image Builder
# =============================================================================

BUILDROOT_DIR  ?= $(CURDIR)/buildroot
BOARD_DIR      := $(CURDIR)/board/universal
CUSTOM_DTS_DIR := $(BOARD_DIR)/custom-dts
OUTPUT_DIR     := $(CURDIR)/output
UNIVERSAL_BOOT := $(OUTPUT_DIR)/universal/boot
FINAL_IMAGE    := $(OUTPUT_DIR)/universal/sdcard.img

# CM5 is consolidated into rpi5 (same BCM2712 SoC, same kernel, same rootfs).
# CM5 DTBs are pulled from the rpi5 build output — no separate build needed.
TARGETS := rpi3 rpi4 rpi5 zero2w cm4

# Your saved defconfigs (never overwritten)
DEFCONFIG_rpi3   := muneuron_rpi3_defconfig     # BCM2710, 64-bit
DEFCONFIG_rpi4   := muneuron_rpi4_defconfig     # BCM2711, 64-bit
DEFCONFIG_rpi5   := muneuron_rpi5_defconfig     # BCM2712, 64-bit (also covers CM5)
DEFCONFIG_zero2w := muneuron_zero2w_defconfig   # BCM2710, 64-bit
DEFCONFIG_cm4    := muneuron_cm4_defconfig      # BCM2711, 64-bit

# Upstream Buildroot defconfigs — used ONCE for bootstrapping only
UPSTREAM_DEFCONFIG_rpi3   := raspberrypi3_64_defconfig
UPSTREAM_DEFCONFIG_rpi4   := raspberrypi4_64_defconfig
UPSTREAM_DEFCONFIG_rpi5   := raspberrypi5_defconfig
UPSTREAM_DEFCONFIG_zero2w := raspberrypizero2w_64_defconfig
UPSTREAM_DEFCONFIG_cm4    := raspberrypicm4io_64_defconfig

# DTBs to pull from each target's build output.
# CM4 DTBs come from the rpi4 build (same BCM2711 SoC).
# CM5 DTBs come from the rpi5 build (same BCM2712 SoC).
DTBS_rpi3   := bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-cm3.dtb
DTBS_rpi4   := bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb \
               bcm2711-rpi-cm4.dtb bcm2711-rpi-cm4s.dtb
DTBS_rpi5   := bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-rpi-500.dtb \
               bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5l-cm5io.dtb
DTBS_zero2w := bcm2710-rpi-zero-2-w.dtb
DTBS_cm4    :=   # Covered by rpi4 build above

# Per-board overlays (space-separated, without .dtbo extension)
OVERLAYS_rpi3   := miniuart-bt
OVERLAYS_rpi4   := miniuart-bt
OVERLAYS_rpi5   := miniuart-bt
OVERLAYS_zero2w := miniuart-bt
OVERLAYS_cm4    := miniuart-bt

# Custom overlays applied to ALL boards (e.g. a HAT present on every device)
OVERLAYS_COMMON :=   # e.g. my-hat my-sensor

# Shared download cache — source tarballs downloaded once, reused across all targets.
# Mount as a separate Docker volume so clean-all never wipes it:
#   docker volume create rpi-buildroot-dl
#   docker run -v rpi-buildroot-dl:/work/dl ...
DL_DIR := $(CURDIR)/dl

# How many targets to build in parallel.
# 5 targets in parallel is safe with 128GB RAM on M4.
# Lower this if you want to leave headroom for other work.
PARALLEL_TARGETS := 5

# Kernel image name (64-bit unified)
KERNEL_IMAGE := Image

# DTC from rpi4's host tools (built by Buildroot)
DTC := $(OUTPUT_DIR)/rpi4/host/bin/dtc

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: all build-all dtbs merge-boot final-image clean clean-all \
        $(addprefix dtbs-,$(TARGETS)) \
        $(addprefix custom-dtbs-,$(TARGETS)) \
        $(addprefix bootstrap-,$(TARGETS)) \
        check-builds help

all: final-image

help:
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "  all              Full build: compile everything + merge + final image"
	@echo "  build-all        Build all targets in parallel"
	@echo "  build-TARGET     Build one target        (e.g. make build-rpi4)"
	@echo "  bootstrap-TARGET First-time config setup (e.g. make bootstrap-rpi4)"
	@echo "  dtbs             Copy and compile all DTBs (including custom)"
	@echo "  merge-boot       Merge boot partitions into universal/boot/"
	@echo "  final-image      Assemble the final sdcard.img"
	@echo "  clean            Remove universal/ output only"
	@echo "  clean-all        Remove ALL build output (preserves dl/ cache)"
	@echo ""
	@echo "  Targets: $(TARGETS)"
	@echo "  CM5 uses rpi5 build output (same BCM2712 SoC)"
	@echo ""

# =============================================================================
# Bootstrap (first-time only)
# Loads upstream defconfig so you have a base to customize with menuconfig.
# After running this, do:
#   make -C buildroot O=output/<target> menuconfig
#   make -C buildroot O=output/<target> savedefconfig BR2_DEFCONFIG=configs/muneuron_<target>_defconfig
# =============================================================================
bootstrap-%:
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
	@echo ">>> Configuring $* from configs/$(DEFCONFIG_$*)"
	@if [ ! -f $(CURDIR)/configs/$(DEFCONFIG_$*) ]; then \
	    echo "ERROR: configs/$(DEFCONFIG_$*) not found."; \
	    echo "       Run 'make bootstrap-$*' first."; \
	    exit 1; \
	fi
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    BR2_DEFCONFIG=$(CURDIR)/configs/$(DEFCONFIG_$*) \
	    defconfig
	@echo ">>> Building $* (this will take a while...)"
	$(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/$* \
	    BR2_DL_DIR=$(DL_DIR) \
	    all
	@touch $(OUTPUT_DIR)/$*/build.done

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
	    if [ ! -f $(OUTPUT_DIR)/$$target/images/rootfs.ext4 ]; then \
	        echo "  MISSING: $$target (run 'make build-$$target')"; \
	        all_ok=0; \
	    else \
	        echo "  OK:      $$target"; \
	    fi; \
	done; \
	if [ $$all_ok -eq 0 ]; then exit 1; fi

# =============================================================================
# DTB handling
# =============================================================================

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
custom-dtbs-%:
	@echo ">>> Compiling custom DTBs/overlays for $*"
	@mkdir -p $(UNIVERSAL_BOOT)/overlays
	@if [ ! -f $(DTC) ]; then \
	    echo "WARNING: dtc not found at $(DTC) — skipping custom DTBs."; \
	    echo "         Run 'make build-rpi4' first to build host tools."; \
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
	@for target_dest in "rpi4:kernel-rpi4.img" "rpi5:kernel-rpi5.img"; do \
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

	@echo ""
	@echo ">>> Boot partition contents:"
	@find $(UNIVERSAL_BOOT) -type f | sort

# =============================================================================
# Final image assembly
# =============================================================================
# Uses genimage to produce a partitioned sdcard.img.
# genimage.cfg must define a FAT boot partition + ext4 rootfs partition.
# We use rpi4's rootfs as the shared userspace (all targets built identically).
GENIMAGE     := genimage
GENIMAGE_CFG := $(BOARD_DIR)/genimage.cfg
ROOTFS       := $(OUTPUT_DIR)/rpi4/images/rootfs.ext4

final-image: merge-boot
	@echo ">>> Assembling final sdcard.img"
	@if [ ! -f $(GENIMAGE_CFG) ]; then \
	    echo "ERROR: $(GENIMAGE_CFG) not found"; exit 1; \
	fi
	@if [ ! -f $(ROOTFS) ]; then \
	    echo "ERROR: rootfs not found at $(ROOTFS)"; exit 1; \
	fi
	@mkdir -p /tmp/empty
	# Copy rootfs into inputpath so genimage finds both boot files and rootfs.ext4
	@cp $(ROOTFS) $(UNIVERSAL_BOOT)/rootfs.ext4
	@mkdir -p $(OUTPUT_DIR)/universal/tmp
	# Clear genimage tmp to avoid stale state
	@rm -rf $(OUTPUT_DIR)/universal/tmp && mkdir -p $(OUTPUT_DIR)/universal/tmp
	$(GENIMAGE) \
	    --config     $(GENIMAGE_CFG) \
	    --rootpath   /tmp/empty \
	    --tmppath    $(OUTPUT_DIR)/universal/tmp \
	    --inputpath  $(UNIVERSAL_BOOT) \
	    --outputpath $(OUTPUT_DIR)/universal
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
	@echo "To clean one target's build:         make -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR)/rpi4 clean"

clean-all:
	rm -rf $(OUTPUT_DIR)
	@echo "All build outputs removed. Download cache in dl/ preserved."
	@echo "To also wipe the download cache:"
	@echo "  docker volume rm rpi-buildroot-dl && docker volume create rpi-buildroot-dl"