# SPDX-License-Identifier: Apache-2.0
#
# Source-build variant of the vllm-tt-metal dev Dockerfile (x86_64 / riscv64 / aarch64)
# Derived from the upstream vllm.tt-metal.src.dev.Dockerfile:
#   1) base image is our self-built tt-metalium image (docker/base.Dockerfile), per arch
#   2) tt-metal / vllm-tt-plugin / tt-smi sources are prepared on the host (02-workdir.sh,
#      which also applies patches/<arch>/) and injected as named build contexts
#   3) build_metal.sh uses --disable-profiler
#   4) SFPI: the official prebuilt package is used when upstream publishes one for the
#      arch (tt-metal's CMake fetches and verifies it); otherwise the toolchain is built
#      from source by sfpi-info.sh BUILD (~10 CPU-hours)
#   5) create_venv.sh uses Python 3.12
#   6) torch comes from the staged wheelhouse when present (riscv64: RISE wheels);
#      otherwise tt-metal's own pin applies (x86_64: torch==2.11.0, resolved from
#      the CPU index so no CUDA stack is pulled in)

# Supplied by 04-image.sh (docker/base.Dockerfile output for this arch)
ARG TT_METAL_DOCKERFILE_URL

# Native builds resolve this name to an empty stage. Quetzal builds override it
# with a sanitized, exact-commit named context supplied by the build script.
FROM scratch AS quetzal_source

# ==============================================================================
# BUILDER STAGE - Contains all build dependencies and artifacts
# ==============================================================================
FROM ${TT_METAL_DOCKERFILE_URL} AS builder

# Build arguments
ARG TT_METAL_COMMIT_SHA_OR_TAG
ARG TT_VLLM_COMMIT_SHA_OR_TAG
ARG TT_QUETZAL_COMMIT_SHA=""
ARG TT_SMI_COMMIT_SHA_OR_TAG=v3.1.1
ARG CONTAINER_APP_UID=1000
ARG DEBIAN_FRONTEND=noninteractive
ARG CONTAINER_APP_USERNAME=container_app_user
ARG HOME_DIR=/home/${CONTAINER_APP_USERNAME}

# Environment variables for build
ENV TT_METAL_COMMIT_SHA_OR_TAG=${TT_METAL_COMMIT_SHA_OR_TAG} \
    SHELL=/bin/bash \
    TZ=America/Los_Angeles \
    CONTAINER_APP_USERNAME=${CONTAINER_APP_USERNAME} \
    ARCH_NAME=wormhole_b0 \
    TT_METAL_HOME=${HOME_DIR}/tt-metal \
    CONFIG=Release \
    TT_METAL_ENV=dev \
    VLLM_TARGET_DEVICE="tt" \
    vllm_tt_plugin_dir=${HOME_DIR}/vllm-tt-plugin \
    TT_SMI_DIR=${HOME_DIR}/tt-smi \
    LOGURU_LEVEL=INFO \
    CPM_USE_LOCAL_PACKAGES=ON \
    # Rust build dependencies, for backward compatibility with tt-metal
    # versions where build Docker image does not have these defined
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    # riscv64: static.rust-lang.org is slow directly, so the Tsinghua mirror is used (vLLM's rust-toolchain pulls 1.95)
    RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup \
    RUSTUP_UPDATE_ROOT=https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup
# Environment variables defined by other env vars
ENV PYTHONPATH=${TT_METAL_HOME} \
    PYTHON_ENV_DIR=${TT_METAL_HOME}/python_env \
    LD_LIBRARY_PATH=${TT_METAL_HOME}/build/lib \
    PATH="$CARGO_HOME/bin:$PATH"

# riscv64: GitHub is blocked, so all git URLs are rewritten through gh-proxy (same as the host ~/.gitconfig)
RUN git config --global --add safe.directory '*' \
    && git config --global url."https://gh-proxy.com/https://github.com/".insteadOf https://github.com/ \
    && git config --global protocol.file.allow always

# riscv64: PyPI goes through the Tsinghua mirror (for uv and pip); the RISE wheelhouse provides riscv64 binary wheels
# (torch/numpy/pandas/matplotlib/pillow; GitHub release assets run at ~2 KB/s, so they are pre-downloaded into the wheelhouse)
ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_FIND_LINKS=/mnt/wheelhouse

# Install only essential build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv \
    python3-dev \
    git \
    build-essential \
    wget \
    curl \
    ca-certificates \
    libgl1 \
    libsndfile1 \
    libffi-dev \
    libssl-dev \
    # pyluwen build dependencies (Rust package with protobuf)
    protobuf-compiler \
    libprotobuf-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# User setup
RUN useradd -u ${CONTAINER_APP_UID} -s /bin/bash -d ${HOME_DIR} ${CONTAINER_APP_USERNAME} \
    && mkdir -p ${HOME_DIR} \
    && chown -R ${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} ${HOME_DIR}

# Give user write access to Rust directories (fail if env vars are missing)
RUN if [ -z "${RUSTUP_HOME}" ] || [ -z "${CARGO_HOME}" ]; then echo "RUSTUP_HOME and CARGO_HOME must be set" >&2; exit 1; fi && \
    mkdir -p "${RUSTUP_HOME}" "${CARGO_HOME}" && \
    chown -R ${CONTAINER_APP_UID}:${CONTAINER_APP_UID} "${RUSTUP_HOME}" "${CARGO_HOME}" && \
    chmod -R 775 "${RUSTUP_HOME}" "${CARGO_HOME}"

# riscv64: the sh.rustup.rs bootstrap script intermittently times out during the build (reachable but the CDN flaps),
# so the pre-downloaded rustup-init binary is used instead (build context rustup-bin);
# the toolchain itself goes through the Tsinghua mirror via RUSTUP_DIST_SERVER (verified to serve riscv64gc).
RUN --mount=type=bind,from=rustup-bin,target=/mnt/rustup-bin,ro \
    /bin/bash -c "cp /mnt/rustup-bin/rustup-init /tmp/rustup-init \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --default-toolchain stable --no-modify-path \
    && rm -f /tmp/rustup-init \
    && . ${CARGO_HOME}/env \
    && rustc --version && cargo --version"

# download.pytorch.org intermittently returns 503 during dependency installs;
# raise uv's HTTP retry count (default 3) for every uv invocation in create_venv.sh.
ENV UV_HTTP_RETRIES=10

# riscv64: tt-metal Python environment (venv) is created BEFORE the C++ build on purpose:
# build_metal.sh builds the ttnn Python bindings against `command -v python3`, so the venv
# must be active to bind them to Python 3.12 (riscv64 torch/numpy/pandas wheels are cp312-only).
# Otherwise `import ttnn` fails with "undefined symbol: PyImport_AddModuleRef" (3.13+ symbol).
#   - create_venv.sh with Python 3.12; torch/numpy/pandas/matplotlib/pillow come from the
#     wheelhouse (RISE riscv64 wheels) via UV_FIND_LINKS
RUN --mount=type=bind,from=tt-metal-src,target=/mnt/tt-metal-src \
    --mount=type=bind,from=wheelhouse,target=/mnt/wheelhouse \
    /bin/bash -c "cp -a /mnt/tt-metal-src ${TT_METAL_HOME} \
    && cd ${TT_METAL_HOME} \
    # tt-metal's requirements-dev.txt carries --extra-index-url .../whl/cpu, but uv
    # prefers the primary index and would install the CUDA torch (several GB of
    # nvidia-* wheels that a Tenstorrent host never uses). unsafe-best-match makes it
    # consider all indexes, so the +cpu local version wins -- same as riscv.
    && export UV_INDEX_STRATEGY=unsafe-best-match \
    && sed -i 's/pdm-backend/pdm-backend cffi/' create_venv.sh \
    && ( for i in 1 2 3 4 5; do CXX=clang++-20 CC=clang-20 bash ./create_venv.sh --python-version 3.12 --force && exit 0; echo 'create_venv.sh failed, retrying in 30s'; sleep 30; done; exit 1 ) \
    && source ${PYTHON_ENV_DIR}/bin/activate \
    && if [ -f 'models/demos/qwen25_vl/requirements.txt' ]; then uv pip install -r models/demos/qwen25_vl/requirements.txt || echo 'WARN: qwen25_vl requirements failed'; fi \
    && if compgen -G '/mnt/wheelhouse/torch-*.whl' >/dev/null; then uv pip install /mnt/wheelhouse/torch-*.whl; fi"

# tt-metal's third_party/CMakeLists.txt does find_package(Boost 1.86 CONFIG REQUIRED)
# and only then falls back to downloading Boost over the network. Ubuntu 22.04 ships
# 1.74 and 26.04 ships 1.90, so install the pinned 1.86 in the builder stage when the
# distro copy is too old (build-only dependency: nothing of this stays in runtime).
RUN set -eu; \
    # clang-20 with libstdc++-11 is too old for ttnn's ranges/concepts usage
    # (levelized_graph.cpp fails on views::filter piping and ranges::for_each), so
    # install the GCC 12 headers when the release offers them; clang then selects the
    # highest GCC installation automatically.
    apt-get update; \
    apt-get install -y --no-install-recommends gcc-12 g++-12 libstdc++-12-dev 2>/dev/null \
      || echo "gcc-12 headers not available on this release, keeping the default"; \
    rm -rf /var/lib/apt/lists/*; \
    clang++-20 -v -E -x c++ /dev/null 2>&1 | grep -E 'Selected GCC installation' || true; \
    # mold refuses LLVM bitcode (LTO) and falls back to "ld.lld", which only exists as
    # the versioned ld.lld-20 here, so the ttnn link died with:
    #   mold: LLVM LTO is detected, so falling back to ld.lld
    #   mold: execvp failed: ld.lld: No such file or directory
    if [ -x /usr/bin/ld.lld-20 ] && [ ! -e /usr/bin/ld.lld ]; then \
      ln -sf /usr/bin/ld.lld-20 /usr/bin/ld.lld; \
    fi; \
    ld.lld --version | head -1 || true; \
    HAVE="$(dpkg-query -W -f='${Version}' libboost-dev 2>/dev/null | cut -d. -f1,2 || true)"; \
    if [ -n "$HAVE" ] && [ "$(printf '%s\n1.86\n' "$HAVE" | sort -V | head -1)" = "1.86" ]; then \
      echo "system Boost ${HAVE} already satisfies tt-metal (>= 1.86)"; \
    else \
      echo "installing Boost 1.86 (system: ${HAVE:-none})"; \
      curl -fsSL --retry 3 -o /tmp/boost.tar.xz \
        "https://gh-proxy.com/https://github.com/boostorg/boost/releases/download/boost-1.86.0/boost-1.86.0-cmake.tar.xz"; \
      echo "2c5ec5edcdff47ff55e27ed9560b0a0b94b07bd07ed9928b476150e16b0efc57  /tmp/boost.tar.xz" \
        | sha256sum -c -; \
      mkdir -p /tmp/boost-src; \
      tar -C /tmp/boost-src --strip-components=1 -xf /tmp/boost.tar.xz; \
      cmake -S /tmp/boost-src -B /tmp/boost-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DBOOST_ENABLE_CMAKE=ON -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBOOST_INCLUDE_LIBRARIES="core;container;smart_ptr;interprocess;asio;lockfree;algorithm"; \
      cmake --build /tmp/boost-build -j"$(nproc)"; \
      cmake --install /tmp/boost-build; \
      rm -rf /tmp/boost-src /tmp/boost-build /tmp/boost.tar.xz; \
    fi; \
    ls -d /usr/local/lib/cmake/Boost-* 2>/dev/null || ls -d /usr/lib/*/cmake/Boost-* 2>/dev/null || true

# Build tt-metal - source injected from host bind mount (pre-cloned on host).
# riscv64 adaptations:
#   - build_metal.sh uses the riscv64 clang-20 toolchain file (patched into tt-metal-src)
#   - --disable-profiler skips Tracy/WASM viewer deps (freetype/glad/glew downloads)
#   - --without-distributed skips the multihost build: its CrossNodeDFB type is only
#     forward-declared in program_impl.hpp, so instantiating the map fails with
#     "field has incomplete type 'tt::tt_metal::experimental::CrossNodeDFB'"
#     (a single-host vLLM image does not need distributed compute)
#   - SFPI: tt-metal's CMake downloads the official package when the arch has a pinned
#     sha256 (x86_64/aarch64); otherwise it uses the staged tarball or sfpi-info.sh BUILD
#     (sfpi-info.sh BUILD compiles binutils+gcc+newlib for riscv-tt-elf, ~10 CPU-h)
#     sfpi-src (pre-cloned on host with submodules) is staged via /mnt/sfpi-src.
#     If a locally-built tarball is provided via /mnt/sfpi-prebuilt, the ~1h toolchain
#     build inside CMake configure is skipped (it is then merely unpacked).
#   - PATH is prefixed with the venv so Python bindings target Python 3.12
RUN --mount=type=bind,from=sfpi-src,target=/mnt/sfpi-src \
    --mount=type=bind,from=sfpi-prebuilt,target=/mnt/sfpi-prebuilt,ro \
    /bin/bash -c "mkdir -p ${TT_METAL_HOME}/runtime \
    && { for so in /usr/lib/gcc/*/*/libstdc++.so; do [ -e \"$so\" ] || continue; d=$(dirname \"$so\"); for x in \"$(dirname \"$d\")\"/*; do [ -d \"$x\" ] || continue; [ \"$x\" = \"$d\" ] && continue; [ -e \"$x/libstdc++.so\" ] && continue; ln -sf \"../$(basename \"$d\")/libstdc++.so\" \"$x/libstdc++.so\" || true; done; done; } \
    && cp -f /mnt/sfpi-prebuilt/*.txz ${TT_METAL_HOME}/runtime/ 2>/dev/null || true \
    && cd ${TT_METAL_HOME} \
    && export PATH=${PYTHON_ENV_DIR}/bin:$PATH \
    && bash ./build_metal.sh --disable-profiler --without-distributed \
    && rm -rf ${TT_METAL_HOME}/.git \
    && rm -rf ${TT_METAL_HOME}/runtime/sfpi-src ${TT_METAL_HOME}/runtime/sfpi-build.log \
    && { uv cache clean || echo 'WARN: uv cache clean failed'; true; }"

# Build vllm-tt-plugin - source injected from host bind mount.
# The plugin owns the vLLM version pin and its dependency overrides, so the
# install is delegated to its own docs/install-vllm-tt.sh rather than restated here.
# vendor/ provides vllm-common.txt (raw.githubusercontent.com is blocked).
# vLLM is built from its sdist with VLLM_TARGET_DEVICE=empty (no CUDA kernels).
# Build isolation is disabled and the backend deps come from the venv, because uv
# would otherwise re-fetch torch/cmake/ninja into a throwaway env and stall.
# Comments cannot live inside the RUN continuation (a double quote would end the
# outer shell string), which is why the rationale sits here.
RUN --mount=type=bind,from=vllm-tt-plugin-src,target=/mnt/vllm-tt-plugin-src \
    --mount=type=bind,from=vendor,target=/mnt/vendor \
    --mount=type=bind,from=wheelhouse,target=/mnt/wheelhouse \
    /bin/bash -c "cp -a /mnt/vllm-tt-plugin-src ${vllm_tt_plugin_dir} \
    && cd ${vllm_tt_plugin_dir} \
    && source ${PYTHON_ENV_DIR}/bin/activate \
    && uv pip install --upgrade pip \
    && uv pip install --no-cache-dir setuptools wheel setuptools-rust setuptools-scm packaging cmake ninja scikit-build-core pybind11 \
    && sed -i 's|--no-binary vllm vllm==|--no-binary vllm --no-build-isolation -v vllm==|' \
         docs/install-vllm-tt.sh \
    && grep -n 'no-binary vllm' docs/install-vllm-tt.sh \
    && source docs/install-vllm-tt.sh \
    && python -c 'import vllm, vllm_tt_plugin; print("vllm", vllm.__version__)' \
    && rm -rf ${vllm_tt_plugin_dir}/.git \
    && { uv cache clean || echo 'WARN: uv cache clean failed'; true; }"

# The optional source is supplied by the authenticated caller as a sanitized
# exact-commit build context. Its read-only mount is not committed to a layer.
# Installing without dependencies preserves the image's pinned tt-metal/vLLM stack.
RUN --mount=type=bind,from=quetzal_source,source=.,target=/tmp/quetzal-source-ro,ro \
    set -eu; \
    if [ -n "${TT_QUETZAL_COMMIT_SHA}" ]; then \
      printf '%s' "${TT_QUETZAL_COMMIT_SHA}" | grep -Eq '^[0-9a-f]{40}$' \
        || { echo 'TT_QUETZAL_COMMIT_SHA must be a lowercase 40-hex commit' >&2; exit 1; }; \
      test -s /tmp/quetzal-source-ro/pyproject.toml \
        || { echo 'Quetzal source context is required for a Quetzal build' >&2; exit 1; }; \
      mkdir -p /tmp/quetzal-source /tmp/quetzal-wheel; \
      cp -a /tmp/quetzal-source-ro/. /tmp/quetzal-source/; \
      cd /tmp/quetzal-source; \
      . "${PYTHON_ENV_DIR}/bin/activate"; \
      uv build --wheel --out-dir /tmp/quetzal-wheel; \
      set -- /tmp/quetzal-wheel/*.whl; \
      [ "$#" -eq 1 ] && [ -f "$1" ] \
        || { echo 'Quetzal build must produce exactly one wheel' >&2; exit 1; }; \
      uv pip install --no-cache-dir --no-deps "$1"; \
      python -c 'import importlib.metadata as m; import serving.artifact_discovery; import tt_quetzalcoatlus.vllm_plugin; eps = [e for e in m.entry_points(group="vllm.general_plugins") if e.name == "quetzal_model_registry"]; assert len(eps) == 1; assert eps[0].value == "tt_quetzalcoatlus.vllm_plugin:register"'; \
      cd /; \
      rm -rf /tmp/quetzal-source /tmp/quetzal-wheel; \
      { uv cache clean || echo 'WARN: uv cache clean failed'; true; }; \
    elif [ -e /tmp/quetzal-source-ro/pyproject.toml ]; then \
      echo 'Quetzal source context requires TT_QUETZAL_COMMIT_SHA' >&2; \
      exit 1; \
    else \
      echo 'Building native-only image (TT_QUETZAL_COMMIT_SHA unset)'; \
    fi

# Build tt-smi in separate venv to avoid conflicts with tt-metal venv
# riscv64: source injected from host bind mount; venv uses uv-managed python 3.12
RUN --mount=type=bind,from=tt-smi-src,target=/mnt/tt-smi-src \
    /bin/bash -c "cp -a /mnt/tt-smi-src ${TT_SMI_DIR} \
    && cd ${TT_SMI_DIR} \
    && /usr/local/bin/python3.12 -m venv .venv \
    && source .venv/bin/activate \
    && pip3 install --upgrade pip \
    && source ${CARGO_HOME}/env \
    && pip3 install . \
    && rm -rf ${TT_SMI_DIR}/.git"

# ==============================================================================
# RUNTIME STAGE - Minimal dependencies for running the application
# ==============================================================================
FROM ${TT_METAL_DOCKERFILE_URL} AS runtime

ARG TT_QUETZAL_COMMIT_SHA=""

LABEL maintainer="Tom Stesco <tstesco@tenstorrent.com>" \
    org.opencontainers.image.source=https://github.com/tenstorrent/tt-inference-server \
    org.opencontainers.image.quetzal.revision=${TT_QUETZAL_COMMIT_SHA}

# IDENTICAL arguments and environment as builder stage
ARG TT_METAL_COMMIT_SHA_OR_TAG
ARG CONTAINER_APP_UID=15863
ARG DEBIAN_FRONTEND=noninteractive
ARG CONTAINER_APP_USERNAME=container_app_user
ARG HOME_DIR=/home/${CONTAINER_APP_USERNAME}
ARG APP_DIR="${HOME_DIR}/app"

# IDENTICAL environment variables as builder stage
ENV TT_METAL_COMMIT_SHA_OR_TAG=${TT_METAL_COMMIT_SHA_OR_TAG} \
    TT_QUETZAL_COMMIT_SHA=${TT_QUETZAL_COMMIT_SHA} \
    SHELL=/bin/bash \
    TZ=America/Los_Angeles \
    CONTAINER_APP_USERNAME=${CONTAINER_APP_USERNAME} \
    ARCH_NAME=wormhole_b0 \
    TT_METAL_HOME=${HOME_DIR}/tt-metal \
    CONFIG=Release \
    TT_METAL_ENV=dev \
    VLLM_TARGET_DEVICE="tt" \
    vllm_tt_plugin_dir=${HOME_DIR}/vllm-tt-plugin \
    TT_SMI_DIR=${HOME_DIR}/tt-smi \
    LOGURU_LEVEL=INFO \
    TT_METAL_LOGS_PATH=${HOME_DIR}/logs
# Environment variables defined by other env vars
ENV PYTHONPATH=${TT_METAL_HOME}:${APP_DIR} \
    PYTHON_ENV_DIR=${TT_METAL_HOME}/python_env \
    LD_LIBRARY_PATH=${TT_METAL_HOME}/build/lib

# Install only runtime dependencies + create IDENTICAL user
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv \
    libgl1 \
    libsndfile1 \
    ca-certificates \
    wget \
    nano \
    acl \
    jq \
    vim \
    # user convenience deps
    htop \
    screen \
    tmux \
    unzip \
    zip \
    curl \
    iputils-ping \
    rsync \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean \
    && useradd -u ${CONTAINER_APP_UID} -s /bin/bash -d ${HOME_DIR} ${CONTAINER_APP_USERNAME} \
    && mkdir -p ${HOME_DIR} ${APP_DIR} ${HOME_DIR}/logs \
    && chown -R ${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} ${HOME_DIR} \
    && echo "source ${PYTHON_ENV_DIR}/bin/activate" >> ${HOME_DIR}/.bashrc

# Copy complete tt-metal installation including virtual environment
COPY --from=builder --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    ${TT_METAL_HOME} ${TT_METAL_HOME}

# Copy the vllm-tt-plugin source tree. This is the editable-install target, so it
# must land at the same absolute path as in builder or the .pth link breaks.
# vLLM itself needs no COPY of its own: it is a regular (non-editable) install
# inside ${PYTHON_ENV_DIR}/site-packages, already copied with TT_METAL_HOME above.
COPY --from=builder --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    ${vllm_tt_plugin_dir} ${vllm_tt_plugin_dir}

# Copy complete tt-smi installation
COPY --from=builder --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    ${TT_SMI_DIR} ${TT_SMI_DIR}

# Copy application files
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "vllm-tt-metal/src" "${APP_DIR}/src"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "vllm-tt-metal/requirements.txt" "${APP_DIR}/requirements.txt"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "utils" "${APP_DIR}/utils"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "VERSION" "${APP_DIR}/VERSION"

# Fix venv symlinks after copy and install additional app requirements
# riscv64: relink to uv-managed python 3.12 (venv was built with 3.12; system python is 3.14)
RUN cd ${PYTHON_ENV_DIR}/bin \
    && rm -f python python3 \
    && ln -s /usr/local/bin/python3.12 python3 \
    && ln -s python3 python \
    && /bin/bash -c "source ${PYTHON_ENV_DIR}/bin/activate \
    && uv pip install --no-cache-dir -r ${APP_DIR}/requirements.txt \
    && uv cache clean" \
    && chown -R ${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} ${PYTHON_ENV_DIR}

# Prove the plugin survived the builder-to-runtime copy and final requirements install.
RUN if [ -n "${TT_QUETZAL_COMMIT_SHA}" ]; then \
      /bin/bash -c "source '${PYTHON_ENV_DIR}/bin/activate' \
        && python -c 'import importlib.metadata as m; import serving.artifact_discovery; import tt_quetzalcoatlus.vllm_plugin; eps = [e for e in m.entry_points(group=\"vllm.general_plugins\") if e.name == \"quetzal_model_registry\"]; assert len(eps) == 1; assert eps[0].value == \"tt_quetzalcoatlus.vllm_plugin:register\"'"; \
    fi

# Fix venv permissions (COPY --chown can break symlink permissions)
RUN chmod -R +x ${PYTHON_ENV_DIR}/bin

# Switch to non-root user for runtime
USER ${CONTAINER_APP_USERNAME}

# Environment variable defaults (can be overridden at runtime with -e)
ENV TT_METAL_LOGS_PATH=/home/container_app_user/logs \
    CACHE_ROOT=/home/container_app_user/cache_root \
    MODEL_SPECS_JSON_PATH=/home/container_app_user/model_specs/model_spec.json \
    VLLM_TARGET_DEVICE=tt \
    WH_ARCH_YAML=wormhole_b0_80_arch_eth_dispatch.yaml

# Create cache_root directory as non-root user to seed Docker volume with correct ownership
RUN mkdir -p ${CACHE_ROOT}

# Copy pre-generated model specs JSON
RUN mkdir -p /home/container_app_user/model_specs
COPY --chown=container_app_user:container_app_user \
    model_spec.json ${MODEL_SPECS_JSON_PATH}

# Set working directory and entrypoint
WORKDIR "${APP_DIR}/src"

# Usage: docker run <image> --model <hf_repo> --device <device_type>
ENTRYPOINT ["/bin/bash", "-c", "source ${PYTHON_ENV_DIR}/bin/activate && exec python run_vllm_api_server.py \"$@\"", "--"]
