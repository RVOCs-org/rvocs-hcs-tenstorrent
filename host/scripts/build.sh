#!/usr/bin/env bash
# tt-dependency-installer build entry point
#
# Usage:
#   ./scripts/build.sh [--arch riscv64|x86_64] [--targets "22.04 24.04 26.04"]
#                      [--proxy cn|direct|auto] [--stage all|fetch|patch|wheels|kmd|bundle|verify]
#                      [--no-patch] [--tools "tt-smi tt-flash tt-topology"]
#                      [--tt-kmd-ref REF] [--tt-umd-ref REF] [--tt-smi-ref REF]
#                      [--tt-flash-ref REF] [--tt-topology-ref REF]
#                      [--bundle-ver VER] [--revert]
#
# Precedence: CLI/env > manifest.yaml(sources.*.ref) > built-in default
# REF may be a tag, a branch or a commit sha (non-tag builds compile the wheel from source)
#
# Stages (sources are fetched at build time, patches are a separate step):
#   fetch   clone the sources from GitHub into work/src (pinned to the ref)
#   patch   apply patches/<component>/series to work/src (skipped with --no-patch)
#   wheels  build the wheelhouse for every target Python version
#   kmd     DKMS source tarball plus prebuilt .ko
#   bundle  assemble tar.zst and .deb, each with a sha256
#   verify  static self-check of the deliverables
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

STAGE=all
REVERT="${REVERT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)              ARCH="$2"; shift 2 ;;
    --targets)           TARGETS="$2"; shift 2 ;;
    --proxy)             PROXY_MODE="$2"; shift 2 ;;
    --stage)             STAGE="$2"; shift 2 ;;
    --no-patch)          SKIP_PATCH=1; shift ;;
    --revert)            REVERT=1; shift ;;
    --tools)             TOOLS="$2"; shift 2 ;;
    --tt-kmd-ref)        TT_KMD_REF="$2"; shift 2 ;;
    --tt-umd-ref)        TT_UMD_REF="$2"; TT_UMD_PINNED=1; shift 2 ;;
    --tt-smi-ref)        TT_SMI_REF="$2"; shift 2 ;;
    --tt-flash-ref)      TT_FLASH_REF="$2"; shift 2 ;;
    --tt-topology-ref)   TT_TOPOLOGY_REF="$2"; shift 2 ;;
    --bundle-ver)        BUNDLE_VER="$2"; shift 2 ;;
    --workdir)           WORK_DIR="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$ARCH" in
  riscv64|x86_64) ;;
  *) die "unsupported architecture: $ARCH (riscv64 / x86_64)" ;;
esac
# Ubuntu release list used by the wheelhouse and the KMD builds. UBUNTU_TARGETS is the
# explicit knob; a bare TARGETS from the environment is only honoured when it really
# looks like a list of releases, because rvocs.sh exports its own TARGETS (the
# orchestration target: tt-host / tt-stack) to the child build.
if [ -n "${UBUNTU_TARGETS:-}" ]; then
  TARGETS="$UBUNTU_TARGETS"
elif [ -n "${TARGETS:-}" ]; then
  case "$TARGETS" in
    *[!0-9.\ ]*)
      warn "ignoring TARGETS='$TARGETS' from the environment (not a list of Ubuntu versions); use UBUNTU_TARGETS to override"
      TARGETS="$(default_targets)"
      ;;
  esac
else
  TARGETS="$(default_targets)"
fi
case "$TARGETS" in
  *[!0-9.\ ]*) die "invalid target list: '$TARGETS' (expected e.g. \"22.04 24.04 26.04\")" ;;
esac
resolve_proxy
export REPO_ROOT WORK_DIR SRC_DIR DIST_DIR PATCH_DIR ARCH TARGETS TOOLS PROXY PROXY_MODE \
       KERNELS BUNDLE_VER REVERT SKIP_PATCH TT_UMD_PINNED \
       TT_KMD_REF TT_UMD_REF TT_SMI_REF TT_FLASH_REF TT_TOPOLOGY_REF
mkdir -p "$WORK_DIR" "$LOG_DIR" "$DIST_DIR"

log "arch: $ARCH   target Ubuntu: $TARGETS"
log "source refs: tt-kmd=$TT_KMD_REF  tt-umd=$TT_UMD_REF  tt-smi=$TT_SMI_REF  tt-flash=$TT_FLASH_REF  tt-topology=$TT_TOPOLOGY_REF"
[ "$SKIP_PATCH" = 1 ] && warn "--no-patch enabled: no patch will be applied in this build"

run_stage() {
  local s="$1" script
  case "$s" in
    fetch)  script=01-fetch.sh ;;
    patch)  script=02-patch.sh ;;
    wheels) script=03-wheels.sh ;;
    kmd)    script=04-kmd.sh ;;
    bundle) script=05-bundle.sh ;;
    verify) script=06-verify-bundle.sh ;;
    *) die "unknown stage: $s" ;;
  esac
  log "========== stage: $s =========="
  if bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$LOG_DIR/build.log"; then
    log "stage finished: $s"
  else
    die "stage failed: $s (see $LOG_DIR/build.log)"
  fi
}

case "$STAGE" in
  all) for s in fetch patch wheels kmd bundle verify; do run_stage "$s"; done
       log "all done. Artifacts in $DIST_DIR" ;;
  *" "*)
       for s in $STAGE; do
         case "$s" in
           fetch|patch|wheels|kmd|bundle|verify) run_stage "$s" ;;
           *) die "invalid stage: $s (available: fetch patch wheels kmd bundle verify)" ;;
         esac
       done ;;
  fetch|patch|wheels|kmd|bundle|verify) run_stage "$STAGE" ;;
  *) die "invalid --stage: $STAGE (available: all fetch patch wheels kmd bundle verify, or space separated)" ;;
esac
