FROM debian:bookworm-20250203

LABEL maintainer="mu-neuron build environment" \
      description="Buildroot container for universal Raspberry Pi image"

ARG TARGETPLATFORM
ARG TAR_VERSION="1.35"

ENV DEBIAN_FRONTEND=noninteractive

# Install 32bit variant on x86_64
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    dpkg --add-architecture i386; \
fi

RUN apt-get -o APT::Retries=3 update -y

RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    apt-get -o APT::Retries=3 install -y --no-install-recommends \
        g++-multilib \
        libc6:i386; \
fi

RUN apt-get -o APT::Retries=3 install -y --no-install-recommends \
        bc \
        build-essential \
        bzr \
        ca-certificates \
        cmake \
        cpio \
        curl \
        cvs \
        file \
        flake8 \
        g++ \
        git \
        libncurses5-dev \
        locales \
        mercurial \
        openssh-server \
        python3 \
        python3-flake8 \
        python3-magic \
        python3-nose2 \
        python3-pexpect \
        python3-pytest \
        qemu-system-arm \
        qemu-system-misc \
        qemu-system-x86 \
        rsync \
        shellcheck \
        subversion \
        unzip \
        wget \
        # Additional deps for our Makefile
        genimage \
        libssl-dev \
        bison \
        flex \
        libelf-dev \
        dosfstools \
        mtools \
        gdisk \
        && \
    apt-get -y autoremove && \
    apt-get -y clean

# Build host-tar (Buildroot requires tar >= 1.35)
RUN curl -sfL https://ftpmirror.gnu.org/tar/tar-${TAR_VERSION}.tar.xz | \
    tar -Jx -C /tmp && \
    cd /tmp/tar-${TAR_VERSION} && \
    FORCE_UNSAFE_CONFIGURE=1 ./configure \
        --disable-year2038 && \
    make && \
    make install && \
    rm -rf /tmp/tar-${TAR_VERSION}

# Locale for toolchain generation
RUN sed -i 's/# \(en_US.UTF-8\)/\1/' /etc/locale.gen && \
    /usr/sbin/locale-gen

ENV LC_ALL=en_US.UTF-8

# Run as root so we can write to the mounted /work volume.
# Buildroot itself doesn't require root — but writing to a macOS-mounted
# volume from a non-root container user causes permission issues.
WORKDIR /work
