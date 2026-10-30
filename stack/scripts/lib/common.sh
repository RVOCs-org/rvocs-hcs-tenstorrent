#!/usr/bin/env bash
# Shared helpers (sourced by the stage scripts, never executed directly)
set -euo pipefail

# Note: this file lives in scripts/lib/, so the repo root is two levels up
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
LOG_DIR="$WORK_DIR/logs"
# Repository version: VERSION is the single source of truth (also used for
# artifact naming). Override with TT_VERSION when needed.
TT_VERSION="${TT_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo v0.1.0)}"
ARCH="${ARCH:-$(uname -m)}"          # x86_64 | aarch64 | riscv64
PROXY_MODE="${PROXY_MODE:-auto}"     # cn | direct | auto
PROXY="${PROXY:-}"                   # 1|0 after resolve_proxy
JOBS="${JOBS:-$(nproc)}"
SFPI_PREBUILT_DIR="${SFPI_PREBUILT_DIR:-}"

# Image names / tags (override with env vars or --image-tag)
# The source-build image is per arch: ubuntu-26.04-riscv64 / ubuntu-26.04-amd64.
# x86_64/aarch64 build on Ubuntu 22.04 (the release upstream tt-metal tests);
# riscv64 needs 26.04, which is where the RISC-V toolchain and packages live.
case "$ARCH" in
  riscv64)       BASE_OS_TAG="ubuntu-26.04-riscv64"; DEFAULT_BASE_OS_IMAGE="ubuntu:26.04" ;;
  aarch64|arm64) BASE_OS_TAG="ubuntu-22.04-arm64";    DEFAULT_BASE_OS_IMAGE="ubuntu:22.04" ;;
  *)             BASE_OS_TAG="ubuntu-22.04-amd64";    DEFAULT_BASE_OS_IMAGE="ubuntu:22.04" ;;
esac
ROOTFS_IMAGE="${ROOTFS_IMAGE:-local/ubuntu:26.04-${ARCH}}"
BASE_IMAGE="${BASE_IMAGE:-local/tt-metal/tt-metalium/${BASE_OS_TAG}:v1}"

# Artifact naming: rvocs-vllm-tt-<image arch>:<repository version>
#   rvocs-vllm-tt-riscv64:v0.1.0
# The image arch follows the OCI convention (amd64 / arm64 / riscv64).
case "$ARCH" in
  riscv64)        IMG_ARCH=riscv64 ;;
  aarch64|arm64)  IMG_ARCH=arm64 ;;
  *)              IMG_ARCH=amd64 ;;
esac
IMAGE_NAME_DEFAULT="rvocs-vllm-tt-${IMG_ARCH}"
IMAGE_TAG_EXPLICIT="${IMAGE_TAG:+1}"   # 1 = caller provided --image-tag / IMAGE_TAG
IMAGE_TAG="${IMAGE_TAG:-${IMAGE_NAME_DEFAULT}:${TT_VERSION}}"

# Base image source (riscv64): the official Ubuntu riscv64 image by default, so no debootstrap / host root is needed
BASE_OS_IMAGE="${BASE_OS_IMAGE:-$DEFAULT_BASE_OS_IMAGE}"
BASE_IMAGE_REF="${BASE_IMAGE_REF:-}"      # Optional: a registry copy of the same content (pulled first when BASE_PULL=1)
BASE_PULL="${BASE_PULL:-0}"               # 1 = try docker pull first (GHCR distribution)
USE_DEBOOTSTRAP="${USE_DEBOOTSTRAP:-0}"   # 1 = build the rootfs with debootstrap inside a container (faithful path, still no host root)
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
# ports.ubuntu.com serves the non-amd64 arches; amd64 uses archive.ubuntu.com
if [ -z "${UBUNTU_MIRROR:-}" ]; then
  case "$ARCH" in
    riscv64|aarch64|arm64) UBUNTU_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
    *)                     UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
  esac
fi

# Refs matching the submodule pins (passed as docker build args, recorded inside the image only)
TT_METAL_REF="${TT_METAL_REF:-v0.79.0-rc11}"
TT_VLLM_PLUGIN_REF="${TT_VLLM_PLUGIN_REF:-d84049e}"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (Ubuntu: sudo apt-get install $1, or see docs/BUILD.md)"; }

# Detect/fix the proxy mode; in cn mode export the mirror environment
resolve_proxy() {
  [ -n "$PROXY" ] && return 0
  case "$PROXY_MODE" in
    cn)     PROXY=1 ;;
    direct) PROXY=0 ;;
    auto)
      if curl -fsSI -m 8 https://github.com >/dev/null 2>&1; then
        PROXY=0
      else
        PROXY=1
        warn "github.com is unreachable, enabling mirror mode (gh-proxy + Tsinghua PyPI/Rust)"
      fi ;;
    *) die "unknown --proxy mode: $PROXY_MODE" ;;
  esac
  if [ "$PROXY" = 1 ]; then
    export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
    export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup
    export RUSTUP_UPDATE_ROOT=https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup
  fi
}

# In cn mode prefix GitHub URLs with gh-proxy
gh_url() { # gh_url <https://github.com/...>
  if [ "${PROXY:-0}" = 1 ]; then echo "https://gh-proxy.com/$1"; else echo "$1"; fi
}

# In cn mode run git with gh-proxy rewriting (without touching the user's global gitconfig)
run_git() {
  if [ "${PROXY:-0}" = 1 ]; then
    git -c "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" "$@"
  else
    git "$@"
  fi
}

# Build workspace layout
work_ctx()      { echo "$WORK_DIR/tt-inference-server"; }          # docker build main context
work_ttmetal()  { echo "$WORK_DIR/tt-inference-server/tt-metal-src"; }
work_plugin()   { echo "$WORK_DIR/tt-inference-server/vllm-tt-plugin-src"; }
work_sfpi()     { echo "$WORK_DIR/sfpi-src"; }
work_ttsmi()    { echo "$WORK_DIR/tt-smi-src"; }
work_rustup()   { echo "$WORK_DIR/rustup-bin"; }
work_sfpipre()  { echo "$WORK_DIR/sfpi-prebuilt"; }

# Per-arch asset layout: assets/<arch>/ holds the files that only make sense for one
# architecture (SFPI package, wheelhouse manifest, rustup pin), while the shared ones
# (CPM bootstrap, vendored requirements) stay in assets/. The flat legacy layout is
# still honoured so existing checkouts keep working.
asset_sfpi_dir()  { echo "$REPO_ROOT/assets/$ARCH/sfpi-prebuilt"; }
asset_file() { # asset_file <name> -> prints the first existing candidate
  local n="$1" p
  for p in "$REPO_ROOT/assets/$ARCH/$n" "$REPO_ROOT/assets/$n"; do
    if [ -f "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

