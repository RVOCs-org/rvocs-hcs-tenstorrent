# TT-Metalium base image (toolchain + uv/python)
# riscv64: the official Ubuntu 26.04 riscv64 image (native linux/riscv64), so
#          **no debootstrap and no host root** are needed
# x86_64/aarch64: the official Ubuntu 22.04 image, which is what upstream tests
#          tt-metal against; clang-20 comes from apt.llvm.org there
# Override with --build-arg BASE_OS_IMAGE (or BASE_OS_IMAGE=... on the command line).
# Package list from tt-metal install_dependencies.sh (debian) + dockerfile/ci-build-light
# + the SFPI source build prerequisites.
ARG BASE_OS_IMAGE=ubuntu:22.04
FROM ${BASE_OS_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Los_Angeles

# The official images ship deb822 sources (26.04) or a plain sources.list (22.04);
# only write the legacy file when it is missing (the debootstrap minbase path has
# main only), and use the codename of the actual image rather than a hardcoded one.
RUN if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ] && [ ! -s /etc/apt/sources.list ]; then \
      . /etc/os-release; \
      case "$(uname -m)" in \
        aarch64|riscv64) MIRROR=ports.ubuntu.com/ubuntu-ports ;; \
        *)               MIRROR=archive.ubuntu.com/ubuntu ;; \
      esac; \
      echo "deb http://${MIRROR} ${VERSION_CODENAME} main restricted universe multiverse" \
        > /etc/apt/sources.list; \
    fi

# clang-20 is in the 26.04 archive but not in 22.04's: pull it from apt.llvm.org when
# the release has no candidate. Everything else comes from the distro.
RUN set -eu; \
    . /etc/os-release; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg; \
    if ! apt-cache policy clang-20 2>/dev/null | grep -q 'Candidate: [0-9]'; then \
      echo "clang-20 not packaged for ${VERSION_CODENAME}; using apt.llvm.org"; \
      wget -qO /etc/apt/trusted.gpg.d/apt.llvm.org.asc https://apt.llvm.org/llvm-snapshot.gpg.key; \
      echo "deb http://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-20 main" \
        > /etc/apt/sources.list.d/llvm.list; \
      apt-get update; \
    fi; \
    apt-get install -y --no-install-recommends \
      build-essential gcc-12 g++-12 libstdc++-12-dev \
      clang-20 lld-20 llvm-20 libclang-20-dev libclang-rt-20-dev clang-tidy-20 \
      libc++-20-dev libc++abi-20-dev \
      mold cmake ninja-build ccache \
      libboost-all-dev libhwloc-dev libnuma-dev libtbb-dev libcapstone-dev libfmt-dev \
      protobuf-compiler libprotobuf-dev pkg-config \
      zlib1g-dev libssl-dev libffi-dev libexpat1-dev \
      libgmp-dev libmpc-dev libmpfr-dev \
      libsndfile1 libgl1 \
      libx11-dev ocl-icd-opencl-dev \
      openmpi-bin libopenmpi-dev \
      git wget curl ca-certificates xz-utils patchelf gosu file jq unzip sudo pandoc xxd \
      python3 python3-dev python3-venv python3-pip \
      autoconf automake bison expect flex gawk patchutils texinfo; \
    apt-get install -y --no-install-recommends libsdl3-dev liblua5.4-dev libisl-dev 2>/dev/null \
      || echo "some optional packages are unavailable on this release, continuing"; \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# tt-metal requires cmake >= 3.24; 22.04 ships 3.22, so take a wheel when the distro
# one is too old (pip installs it into /usr/local/bin, ahead of /usr/bin).
RUN set -eu; \
    HAVE="$(cmake --version | head -1 | awk '{print $3}')"; \
    if [ "$(printf '%s\n3.24\n' "$HAVE" | sort -V | head -1)" != "3.24" ]; then \
      echo "cmake ${HAVE} is too old for tt-metal; installing a newer one from PyPI"; \
      pip3 install --no-cache-dir cmake || pip3 install --break-system-packages --no-cache-dir cmake; \
    fi; \
    cmake --version | head -1

# Ubuntu 26.04 ships libstdc++6 from GCC 16 but only libstdc++-15-dev, and clang
# picks the (dev-less) gcc-16 directory, so linking dies with
# "cannot find -lstdc++". Point the other gcc dirs at the installed dev library.
# (No-op on 22.04, where the gcc and libstdc++ versions agree.)
RUN set -eu; for so in /usr/lib/gcc/*/*/libstdc++.so; do [ -e "$so" ] || continue; d=$(dirname "$so"); for x in "$(dirname "$d")"/*; do [ -d "$x" ] || continue; [ "$x" = "$d" ] && continue; [ -e "$x/libstdc++.so" ] && continue; ln -sf "../$(basename "$d")/libstdc++.so" "$x/libstdc++.so" || true; done; done

# unversioned clang symlinks (tt-metal's toolchain file uses clang-20; convenience only)
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-20 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-20 100 \
    && if [ -x /usr/bin/ld.lld-20 ] && [ ! -e /usr/bin/ld.lld ]; then \
         ln -sf /usr/bin/ld.lld-20 /usr/bin/ld.lld; \
       fi \
    && clang --version | head -1

# The official Ubuntu image ships ubuntu:ubuntu (UID/GID 1000) while the main image runs useradd -u 1000
# to create container_app_user, which fails with "UID 1000 is not unique". Remove it so the base image
# matches debootstrap minbase (no 1000 user) and assert that 1000 is free.
RUN set -eux; \
    if id -u 1000 >/dev/null 2>&1; then \
      u="$(id -un 1000)"; userdel -r "$u" 2>/dev/null || userdel "$u"; \
    fi; \
    if getent group 1000 >/dev/null 2>&1; then \
      g="$(getent group 1000 | cut -d: -f1)"; groupdel "$g" 2>/dev/null || true; \
    fi; \
    ! id -u 1000 >/dev/null 2>&1

# uv + a preinstalled uv-managed Python 3.12 (used by create_venv.sh; the tt-metal
# python environment must be 3.12 for the ttnn bindings)
# Direct PyPI is slow here, so everything goes through the Tsinghua mirror
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python
# GitHub release assets are slow directly, so they go through gh-proxy
ENV UV_PYTHON_INSTALL_MIRROR=https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download
ENV UV_HTTP_RETRIES=10
RUN pip3 install --no-cache-dir uv || pip3 install --break-system-packages --no-cache-dir uv; \
    uv python install 3.12 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3.12 \
    && /usr/local/bin/python3.12 --version \
    && uv --version
