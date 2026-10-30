#!/usr/bin/env bash
# One-shot build entry point for the Tenstorrent software stack.
#
# Usage:
#   ./scripts/build.sh [--proxy cn|direct|auto] [--stage all|prep|fetch|workdir|base|image|verify]
#                      [--arch x86_64|riscv64] [--workdir DIR] [--image-tag TAG]
#                      [--sfpi-prebuilt DIR] [--no-sfpi-prebuilt]
#
# SFPI toolchain (riscv64), three options in decreasing priority:
#   1) --no-sfpi-prebuilt          compile from source in the container (~90 minutes)
#   2) --sfpi-prebuilt DIR         use sfpi_*.txz from the given directory
#   3) default                     use the bundled assets/<arch>/sfpi-prebuilt/*.txz (only after the pre-flight check)
#
# Stages (riscv64 needs the patches/riscv64 layer, included on master):
#   prep     same as fetch + workdir: prepare editable, patched sources without building an image
#   fetch    update git submodules and download/verify the offline assets (wheelhouse / rustup-init)
#   workdir  create self-contained source trees (local clone, not cp of submodules), apply riscv64 patches, SFPI pre-flight, place assets
#   base     build the riscv64 base image (FROM the official ubuntu:26.04 by default; no root, no debootstrap)
#   image    docker build the main image (tt-metal + vLLM + plugin + tt-smi)
#   verify   image acceptance checks (ttnn/vllm imports, entry points, SFPI toolchain, ...)
#
# Stages (x86_64/aarch64, master branch):
#   fetch -> image -> verify (upstream Dockerfile; convenience path, experimental)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

STAGE=all
NO_SFPI_PREBUILT="${NO_SFPI_PREBUILT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)             ARCH="$2"; shift 2 ;;
    --proxy)            PROXY_MODE="$2"; shift 2 ;;
    --stage)            STAGE="$2"; shift 2 ;;
    --workdir)          WORK_DIR="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
    --image-tag)        IMAGE_TAG="$2"; shift 2 ;;
    --sfpi-prebuilt)    SFPI_PREBUILT_DIR="$2"; shift 2 ;;
    --no-sfpi-prebuilt) NO_SFPI_PREBUILT=1; shift ;;
    -h|--help)          usage ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$ARCH" in
  riscv64|x86_64|aarch64) ;;
  *) die "unsupported platform: $ARCH" ;;
esac

resolve_proxy
export REPO_ROOT WORK_DIR ARCH PROXY_MODE PROXY JOBS IMAGE_TAG BASE_IMAGE ROOTFS_IMAGE \
       SFPI_PREBUILT_DIR NO_SFPI_PREBUILT \
       BASE_OS_IMAGE BASE_IMAGE_REF BASE_PULL USE_DEBOOTSTRAP UBUNTU_CODENAME UBUNTU_MIRROR
mkdir -p "$WORK_DIR" "$LOG_DIR"

if [ ! -d "$REPO_ROOT/docker" ]; then
  die "missing docker/ (the source-build Dockerfiles are required)"
fi

# Every arch uses the same source-build pipeline: sources are fetched, patched and
# injected as named contexts, then tt-metal / vLLM are compiled inside the image.
STAGES="fetch workdir base image verify"

run_stage() {
  local s="$1" script
  case "$s" in
    fetch)   script=01-fetch.sh ;;
    workdir) script=02-workdir.sh ;;
    base)    script=03-base-image.sh ;;
    image)   script=04-image.sh ;;
    verify)  script=05-verify.sh ;;
    *) die "unknown stage: $s" ;;
  esac
  log "========== stage: $s =========="
  if bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$LOG_DIR/build.log"; then
    log "stage finished: $s"
  else
    die "stage failed: $s (see $LOG_DIR/build.log and the output above)"
  fi
}

if [ "$STAGE" = all ]; then
  for s in $STAGES; do run_stage "$s"; done
  log "all done. Image: $IMAGE_TAG"
elif [ "$STAGE" = prep ]; then
  # Prepare patched sources only, no image; lets a developer edit code and then run --stage image
  run_stage fetch
  run_stage workdir
  log "source workspace ready (patched): $WORK_DIR"
  log "edit the sources here; make changes permanent as a patch (see the developer workflow in docs/BUILD.md), then run ./scripts/build.sh --stage image"
else
  # One or more stages, space separated: --stage "fetch workdir"
  for s in $STAGE; do
    case " $STAGES " in
      *" $s "*) run_stage "$s" ;;
      *) die "invalid stage: $s (available: prep $STAGES)" ;;
    esac
  done
fi
