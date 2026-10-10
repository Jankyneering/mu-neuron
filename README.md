# µNeuron

A light OS for SDR base stations and hotspots.

**Priority target: Raspberry Pi 3 (3B / 3B+).** A plain `make` produces a
ready-to-flash Pi 3 SD card image. Other SoC families are one flag away:

| Target    | Boards                              | SoC      |
|-----------|-------------------------------------|----------|
| `rpi3`    | Pi 3B / 3B+ / Zero 2W / CM3         | BCM2710  |
| `rpi4`    | Pi 4B / 400 / CM4 / CM4s            | BCM2711  |
| `rpi5`    | Pi 5 / 500 / CM5                    | BCM2712  |

A multi-board "universal" image (one card boots any of the boards above) is
still available via `make universal`.

## Building

### From a fresh clone

```zsh
# 1. Clone with submodules
git clone --recurse-submodules https://your-repo/mu-neuron.git
cd mu-neuron

# 2. Build the Docker image (once per machine)
docker build -t rpi-buildroot .

# 3. Create the persistent output volume (once per machine)
mkdir -p output dl
docker volume create rpi-buildroot-output
docker volume create rpi-buildroot-dl

# 4. Build the Raspberry Pi 3 image (default target)
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -v rpi-buildroot-dl:/work/dl \
    -w /work \
    rpi-buildroot make
```

The image lands at `output/rpi3/images/sdcard.img`.

### Day to day commands

```zsh
# Incremental build (after changing a defconfig or package)
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot make

# Build another SoC family
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot make build-rpi4

# Build the multi-board universal image (needs all targets built)
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot make universal

# Copy the final image to your Mac
docker run --rm \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot cp /work/output/rpi3/images/sdcard.img /work/sdcard.img

# Flash it
sudo dd if=sdcard.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### Shell alias

```zsh
# Create alias (or add to .zshrc/.bashrc)
alias rpi-make='docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -v rpi-buildroot-dl:/work/dl \
    -w /work \
    rpi-buildroot make'

# Usage
rpi-make                    # Build the Pi 3 image (default, fast)
rpi-make TARGET=rpi4        # Build another SoC family
rpi-make build-rpi4         # Same, Make-style
rpi-make universal          # Build everything + multi-board image (slow)
rpi-make clean              # Clean build outputs but keep target builds
```

## Adding a board to a family

To support a new board that shares a SoC with an existing family (e.g. a
future Pi that reuses BCM2711):

1. Add its DTB name to `DTBS_<family>` in the `Makefile`.
2. Add its DTS name to `BR2_LINUX_KERNEL_INTREE_DTS_NAME` in
   `configs/muneuron_<family>_defconfig`.

The RPi bootloader picks the right DTB from the boot partition automatically
based on the board model — no other changes needed.

## Acknowledgements & License

Made with ❤️, lots of ☕️, and lack of 😴
Published under GNU AGPLv3
[![License: AGPL v3](https://www.gnu.org/graphics/agplv3-155x51.png)](https://www.gnu.org/licenses/agpl-3.0.en.html)  [GNU AGPLv3](https://www.gnu.org/licenses/agpl-3.0.en.html)
