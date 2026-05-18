# µNeuron

A light OS for SDR base stations and hotspots.

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

# 4. Build everything
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -v rpi-buildroot-dl:/work/dl \
    -w /work \
    rpi-buildroot make all
```

### Day to day commands

```zsh
# Incremental build (after changing a defconfig or package)
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot make build-rpi4

# Re-merge and re-image after any build change
docker run --rm -it \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot make merge-boot final-image

# Copy the final image to your Mac
docker run --rm \
    -v $(pwd):/work \
    -v rpi-buildroot-output:/work/output \
    -w /work \
    rpi-buildroot cp /work/output/universal/sdcard.img /work/sdcard.img

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
rpi-make all        # Build everything (slow)
rpi-make build-*    # Build a specific target (faster)
rpi-make clean      # Clean build outputs but keep target builds
```

## Acknowledgements & License

Made with ❤️, lots of ☕️, and lack of 🛌  

Published under GNU AGPLv3

[![License: AGPL v3](https://www.gnu.org/graphics/agplv3-155x51.png)](https://www.gnu.org/licenses/agpl-3.0.en.html)  
[GNU AGPLv3](https://www.gnu.org/licenses/agpl-3.0.en.html)
