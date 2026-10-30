#!/usr/bin/env bash
# Stage 4: build the main image
#   riscv64: custom Dockerfile (venv before the C++ build, SFPI prebuilt or from source, sources injected as named contexts)
#   x86_64/aarch64: upstream Dockerfile (convenience path, experimental)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd docker

if [ "${UPSTREAM_IMAGE_PATH:-0}" != 1 ]; then
  DF="$REPO_ROOT/docker/vllm.tt-metal.src.dev.source.Dockerfile"
  [ -f "$DF" ] || die "missing $DF (source-build Dockerfile)"
  CTX="$(work_ctx)"
  [ -d "$CTX/tt-metal-src" ] || die "workspace not prepared (run --stage workdir first)"
  [ -d "$CTX/wheelhouse" ] || die "wheelhouse not in place (run --stage fetch first)"
  mkdir -p "$(work_sfpipre)"   # allow an empty named context

  if compgen -G "$(work_sfpipre)/*.txz" >/dev/null; then
    log "  SFPI: reusing the prebuilt package $(basename "$(ls -1 "$(work_sfpipre)"/*.txz | head -1)") (toolchain build skipped)"
  else
    log "  SFPI: building the toolchain from source in the container (~90 minutes)"
  fi

  log "building the source image ($ARCH, all sources from named contexts) ..."
  log "  tag: $IMAGE_TAG"
  DOCKER_BUILDKIT=1 docker build \
    --network host \
    --build-context tt-metal-src="$(work_ttmetal)" \
    --build-context sfpi-src="$(work_sfpi)" \
    --build-context wheelhouse="$CTX/wheelhouse" \
    --build-context vllm-tt-plugin-src="$(work_plugin)" \
    --build-context vendor="$CTX/vendor" \
    --build-context tt-smi-src="$(work_ttsmi)" \
    --build-context rustup-bin="$(work_rustup)" \
    --build-context sfpi-prebuilt="$(work_sfpipre)" \
    -t "$IMAGE_TAG" \
    --build-arg TT_METAL_DOCKERFILE_URL="$BASE_IMAGE" \
    --build-arg TT_METAL_COMMIT_SHA_OR_TAG="$TT_METAL_REF" \
    --build-arg TT_VLLM_COMMIT_SHA_OR_TAG="$TT_VLLM_PLUGIN_REF" \
    --build-arg CONTAINER_APP_UID=1000 \
    -f "$DF" \
    "$CTX"
elif [ "${UPSTREAM_IMAGE_PATH:-0}" = 1 ]; then
  # Opt-in escape hatch: build with the upstream Dockerfile instead of building
  # tt-metal/vLLM from our patched sources (UPSTREAM_IMAGE_PATH=1).
  # Upstream path (x86_64/aarch64): official Dockerfile and official base image.
  # Note: this path is not continuously validated here; it is a convenience entry point.
  DF="$REPO_ROOT/upstream/tt-inference-server/vllm-tt-metal/vllm.tt-metal.src.dev.Dockerfile"
  [ -f "$DF" ] || die "missing the upstream Dockerfile: $DF (submodules not initialized? run --stage fetch)"

  # The upstream Dockerfile takes its tt-metalium base image as a build arg with no
  # default (upstream passes it from scripts/build_single_docker.sh), so it must be
  # resolved here. Order: explicit override > locally built image > published image.
  case "$ARCH" in
    x86_64)  DEB_ARCH=amd64 ;;
    aarch64) DEB_ARCH=arm64 ;;
    *)       DEB_ARCH="$ARCH" ;;
  esac
  BASE_OS_TAG="ubuntu-${X86_UBUNTU_VERSION:-22.04}-${DEB_ARCH}"
  if [ -z "${TT_METAL_DOCKERFILE_URL:-}" ]; then
    local_base="local/tt-metal/tt-metalium/${BASE_OS_TAG}:${TT_METAL_REF}"
    if docker image inspect "$local_base" >/dev/null 2>&1; then
      TT_METAL_DOCKERFILE_URL="$local_base"
    else
      TT_METAL_DOCKERFILE_URL="ghcr.io/tenstorrent/tt-metal/tt-metalium/${BASE_OS_TAG}:${TT_METAL_REF}"
    fi
  fi
  # Always use the RVOCs naming rule here; the upstream tt-inference-server tag
  # is only relevant when pulling their prebuilt base image.
  if [ "${IMAGE_TAG_EXPLICIT:-0}" != 1 ]; then
    IMAGE_TAG="${IMAGE_NAME_DEFAULT}:${TT_VERSION}"
  fi
  log "  base image: $TT_METAL_DOCKERFILE_URL"
  if ! docker image inspect "$TT_METAL_DOCKERFILE_URL" >/dev/null 2>&1; then
    log "  pulling the base image (the upstream Dockerfile has no default) ..."
    docker pull "$TT_METAL_DOCKERFILE_URL" \
      || die "cannot obtain the tt-metalium base image: $TT_METAL_DOCKERFILE_URL \
(override with TT_METAL_DOCKERFILE_URL=<image>, or build it from tt-metal/dockerfile and retry)"
  fi
  log "building the upstream image ($ARCH, experimental path) ..."
  DOCKER_BUILDKIT=1 docker build \
    --network host \
    -t "$IMAGE_TAG" \
    --build-arg TT_METAL_DOCKERFILE_URL="$TT_METAL_DOCKERFILE_URL" \
    --build-arg TT_METAL_COMMIT_SHA_OR_TAG="$TT_METAL_REF" \
    --build-arg TT_VLLM_COMMIT_SHA_OR_TAG="$TT_VLLM_PLUGIN_REF" \
    --build-arg CONTAINER_APP_UID=1000 \
    -f "$DF" \
    "$REPO_ROOT/upstream/tt-inference-server"
fi

log "image build finished: $IMAGE_TAG"
