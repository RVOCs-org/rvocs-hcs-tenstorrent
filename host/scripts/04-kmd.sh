#!/usr/bin/env bash
# Stage 3: package tt-kmd (sources from work/src/tt-kmd, patched) into a DKMS tarball plus optional prebuilt .ko
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KMD_SRC="$SRC_DIR/tt-kmd"
[ -d "$KMD_SRC" ] || die "missing source $KMD_SRC (run --stage fetch first)"
[ -f "$KMD_SRC/dkms.conf" ] || die "tt-kmd has no dkms.conf (wrong version?)"

KMD_VER="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$KMD_SRC/dkms.conf" | head -1)"
[ -n "$KMD_VER" ] || die "cannot determine the tt-kmd version"
log "tt-kmd version: $KMD_VER ($(git -C "$KMD_SRC" describe --tags 2>/dev/null || echo '?'))"
has_patches tt-kmd && log "  patches/tt-kmd/series applied"

KMD_OUT="$WORK_DIR/kmd"
KMD_DIR="$KMD_OUT/tenstorrent-$KMD_VER"
rm -rf "$KMD_DIR" "$KMD_OUT/prebuilt"
mkdir -p "$KMD_OUT"
cp -a "$KMD_SRC/." "$KMD_DIR/"
rm -rf "$KMD_DIR/.git" "$KMD_DIR/.github"
tar czf "$KMD_OUT/tenstorrent-$KMD_VER.tar.gz" -C "$KMD_OUT" "tenstorrent-$KMD_VER"
log "DKMS source tarball: tenstorrent-$KMD_VER.tar.gz ($(du -h "$KMD_OUT/tenstorrent-$KMD_VER.tar.gz" | cut -f1))"

# Kernel list: KERNELS env var, else targets.<arch>.kernels from manifest.yaml
if [ -z "${KERNELS:-}" ]; then
  KERNELS="$(python3 "$SCRIPT_DIR/lib/manifest_kernels.py" "$REPO_ROOT/manifest.yaml" "$ARCH" 2>/dev/null)"
fi
[ -n "${KERNELS:-}" ] || KERNELS="$(uname -r)"
log "prebuild kernels: $KERNELS (host runs $(uname -r))"
# uname -m -> kernel ARCH name
case "$ARCH" in
  riscv64) KARCH=riscv ;;
  x86_64)  KARCH=x86 ;;
  aarch64) KARCH=arm64 ;;
  *)       KARCH="$ARCH" ;;
esac

if [ -n "${KERNELS:-}" ]; then
  for k in $KERNELS; do
    bdir="/lib/modules/$k/build"
    if [ ! -d "$bdir" ]; then warn "kernel $k has no headers, skipping prebuild (target falls back to DKMS)"; continue; fi
    log "prebuilding the module for kernel $k ..."
    # the kernel tree expects KARCH (riscv / x86 / arm64), not uname -m (riscv64 / x86_64)
    make -C "$bdir" M="$KMD_DIR" ARCH="$KARCH" modules >"$LOG_DIR/kmd-$k.log" 2>&1 \
      || { warn "kernel $k build failed (see $LOG_DIR/kmd-$k.log)"; continue; }
    ko=$(find "$KMD_DIR" -maxdepth 2 -name 'tenstorrent.ko' | head -1)
    [ -n "$ko" ] || { warn "tenstorrent.ko not found"; continue; }
    mkdir -p "$KMD_OUT/prebuilt/$k"
    cp "$ko" "$KMD_OUT/prebuilt/$k/tenstorrent.ko"
    zstd -q -f "$KMD_OUT/prebuilt/$k/tenstorrent.ko" -o "$KMD_OUT/prebuilt/$k/tenstorrent.ko.zst"
    rm -f "$KMD_OUT/prebuilt/$k/tenstorrent.ko"
    log "prebuilt: prebuilt/$k/tenstorrent.ko.zst"
  done
fi

log "kmd stage finished"
