#!/usr/bin/env bash
# Stage 1: fetch sources and offline assets
#   - git submodules (official repos pinned as-is): top level first, then recursive (irrelevant nested ones are skipped)
#   - riscv64: sfpi toolchain submodules (binutils/gcc/newlib, about 2 GB)
#   - riscv64: wheelhouse (RISE index) and rustup-init (sha256 verified)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_proxy
require_cmd git
require_cmd curl

# ---------------------------------------------------------------- submodules
[ -f "$REPO_ROOT/.gitmodules" ] || die "missing .gitmodules (incomplete checkout?)"

# Nested submodules that are irrelevant to the image build and always fail on this network:
#   - kvcache-ai/Mooncake uses an SSH URL (always fails without a key)
#   - tenstorrent/tt-llm-engine asks for interactive auth through gh-proxy
# Both live under tt-inference-server/tt-media-server and are never used by the Dockerfile.
# The same list is kept in manifest.yaml (ignored_submodules) so it can be maintained as upstream moves.
IGNORED_SUBMODULES=(
  "tt-media-server/cpp_server/third_party/Mooncake"
  "tt-media-server/cpp_server/tt-llm-engine"
)

# Two-step update (A2):
#   1) top level without recursion, so the five upstream repos land first;
#   2) mark the irrelevant submodules update=none inside tt-inference-server, then recurse,
#      so future build-related submodules are still fetched and only the known-irrelevant ones are skipped.
log "updating git submodules (top level, no recursion, proxy=$PROXY) ..."
TOPDEPTH=()
[ "${SUBMODULE_DEPTH:-1}" != 0 ] && TOPDEPTH=(--depth "${SUBMODULE_DEPTH:-1}")

if ! run_git -C "$REPO_ROOT" submodule update --init "${TOPDEPTH[@]}" 2>&1; then
  warn "top-level submodule update failed: usually a network interruption. Retry, or use --proxy cn"
  die "submodule update failed"
fi

TIS="$REPO_ROOT/upstream/tt-inference-server"
if [ -e "$TIS/.git" ]; then
  for sub in "${IGNORED_SUBMODULES[@]}"; do
    git -C "$TIS" config "submodule.$sub.update" none 2>/dev/null || true
  done
  log "skipped irrelevant submodules: ${IGNORED_SUBMODULES[*]}"
fi

# Submodule history is not needed: the pins are exact commits, and the image build
# takes the refs from manifest.yaml. Shallow clones keep the first run to a few
# hundred MB instead of several GB (SUBMODULE_DEPTH=0 restores full history).
DEPTH_ARGS=()
if [ "${SUBMODULE_DEPTH:-1}" != 0 ]; then
  DEPTH_ARGS=(--depth "${SUBMODULE_DEPTH:-1}")
  log "shallow submodule clone (depth ${SUBMODULE_DEPTH:-1}); set SUBMODULE_DEPTH=0 for full history"
fi

log "updating nested submodules (recursive, irrelevant ones excluded) ..."
if ! run_git \
      -c submodule."tt-media-server/cpp_server/third_party/Mooncake".update=none \
      -c submodule."tt-media-server/cpp_server/tt-llm-engine".update=none \
      -C "$REPO_ROOT" submodule update --init "${DEPTH_ARGS[@]}" --recursive 2>&1; then
  warn "recursive update failed: usually a new irrelevant submodule or a network interruption"
  warn "  fetch a single item: git -C upstream/<repo> submodule update --init <path>"
  warn "  if the submodule really is irrelevant, add it to IGNORED_SUBMODULES in scripts/01-fetch.sh and to manifest.yaml"
  die "submodule update failed"
fi

# sfpi toolchain sources: only needed when SFPI has to be built from source.
# x86_64/aarch64 normally use the official prebuilt package that tt-metal's CMake
# downloads; the sources are still fetched so the fallback works without a re-fetch.
if [ "$ARCH" = riscv64 ] || [ "${FETCH_SFPI_SOURCES:-1}" = 1 ]; then
  log "fetching the sfpi toolchain submodules (binutils/gcc/newlib, about 2 GB, first time only) ..."
  run_git -C "$REPO_ROOT/upstream/sfpi" submodule update --init --recursive \
    || warn "sfpi submodule fetch failed (only needed for a source build with --no-sfpi-prebuilt)"

  if [ "$ARCH" = riscv64 ] && { [ "${NO_SFPI_PREBUILT:-0}" = 1 ] || ! compgen -G "$(asset_sfpi_dir)/*.txz" "$REPO_ROOT/assets/sfpi-prebuilt/*.txz" >/dev/null; }; then
    miss=0
    for p in binutils gcc newlib; do
      if [ -z "$(ls -A "$REPO_ROOT/upstream/sfpi/$p" 2>/dev/null)" ]; then
        warn "missing sfpi submodule: $p"
        warn "  fix: git -C $REPO_ROOT/upstream/sfpi submodule update --init $p"
        miss=1
      fi
    done
    [ "$miss" = 0 ] || die "incomplete sfpi compiler sources (required for a source build): fetch the submodules, or supply --sfpi-prebuilt / the bundled package"
  elif [ "$ARCH" = riscv64 ]; then
    log "SFPI prebuilt package present: skipping the sfpi submodule check (only needed for a source build)"
  else
    log "sfpi sources fetched for the fallback path (SFPI is downloaded prebuilt for $ARCH)"
  fi
fi

# ------------------------------------------------- offline assets
WH="$WORK_DIR/assets/wheelhouse"
FL="$WORK_DIR/assets/files"
mkdir -p "$WH" "$FL"

# rustup-init: vLLM's rust-toolchain is built against the host rustup, so every
# arch needs the matching binary. Pin per arch when assets/rustup-init-<arch>.sha256
# exists; otherwise record the sha256 of what was fetched for later pinning.
case "$ARCH" in
  riscv64)        RUSTUP_TRIPLE=riscv64gc-unknown-linux-gnu ;;
  aarch64|arm64)  RUSTUP_TRIPLE=aarch64-unknown-linux-gnu ;;
  *)              RUSTUP_TRIPLE=x86_64-unknown-linux-gnu ;;
esac
RSHA=""
for cand in "$REPO_ROOT/assets/$ARCH/rustup-init-${ARCH}.sha256" "$REPO_ROOT/assets/$ARCH/rustup-init.sha256" "$REPO_ROOT/assets/rustup-init.sha256"; do
  [ -f "$cand" ] || continue
  case "$cand" in
    *rustup-init.sha256) [ "$ARCH" = riscv64 ] || continue ;;   # legacy file pins riscv64gc
  esac
  RSHA="$(head -1 "$cand" | awk '{print $1}')"
  break
done
if [ -f "$FL/rustup-init" ] && { [ -z "$RSHA" ] || echo "$RSHA  $FL/rustup-init" | sha256sum -c --status 2>/dev/null; }; then
  log "rustup-init already present ($RUSTUP_TRIPLE)"
else
  RURL="https://github.com/rust-lang/rustup/releases/download/1.28.2/rustup-init-${RUSTUP_TRIPLE}"
  log "downloading rustup-init ($RUSTUP_TRIPLE) ..."
  curl -fSL --retry 3 --connect-timeout 20 -o "$FL/rustup-init" "$(gh_url "$RURL")" \
    || curl -fSL --retry 3 -o "$FL/rustup-init" \
         "https://static.rust-lang.org/rustup/dist/${RUSTUP_TRIPLE}/rustup-init"
  chmod +x "$FL/rustup-init"
  if [ -n "$RSHA" ]; then
    echo "$RSHA  $FL/rustup-init" | sha256sum -c --status \
      || die "rustup-init sha256 mismatch for $RUSTUP_TRIPLE (expected $RSHA)"
  else
    warn "no pinned sha256 for rustup-init ($RUSTUP_TRIPLE); recording it under work/assets/files"
    sha256sum "$FL/rustup-init" | awk '{print $1}' > "$FL/rustup-init.sha256.${ARCH}"
  fi
fi

# SFPI: download the official prebuilt toolchain when upstream publishes one for
# this arch. tt-metal's sfpi-version carries the version, repo and per-arch sha256,
# so the file we stage is exactly what its CMake would have fetched. riscv64 has no
# official package (the bundled txz or a source build is used instead).
if [ "$ARCH" != riscv64 ]; then
  VERFILE="$REPO_ROOT/upstream/tt-metal/tt_metal/sfpi-version"
  if [ -f "$VERFILE" ]; then
    SVER="$(sed -n "s/^sfpi_version='\(.*\)'/\1/p" "$VERFILE" | head -1)"
    SREPO="$(sed -n "s/^sfpi_repo='\(.*\)'/\1/p" "$VERFILE" | head -1)"
    SHASH="$(sed -n "s/^sfpi_${ARCH}_debian_txz_hash='\(.*\)'/\1/p" "$VERFILE" | head -1)"
    if [ -n "$SVER" ] && [ -n "$SHASH" ]; then
      SFN="sfpi_${SVER}_${ARCH}_debian.txz"
      SP="$(asset_sfpi_dir)"
      mkdir -p "$SP"
      if [ -f "$SP/$SFN" ] && echo "$SHASH  $SP/$SFN" | sha256sum -c --status 2>/dev/null; then
        log "SFPI prebuilt already present: $SFN"
      else
        log "downloading the official SFPI package: $SFN"
        curl -fSL --retry 3 --connect-timeout 20 -o "$SP/$SFN" \
          "$(gh_url "$SREPO/releases/download/$SVER/$SFN")" \
          || die "cannot download the SFPI package: $SREPO/releases/download/$SVER/$SFN"
        echo "$SHASH  $SP/$SFN" | sha256sum -c --status \
          || die "SFPI sha256 mismatch: $SFN (expected $SHASH)"
      fi
    else
      log "no official SFPI package for $ARCH (no pinned sha256) -> prebuilt skip"
    fi
  fi
fi

# RISE wheelhouse: riscv64 has no PyPI wheels for torch/numpy/pandas, x86 does.
ASSET_SHA="$(asset_file wheelhouse.sha256 || echo "$REPO_ROOT/assets/$ARCH/wheelhouse.sha256")"
if [ "$ARCH" = riscv64 ] && [ -f "$ASSET_SHA" ]; then
  # wheelhouse: RISE index (files hosted on GitHub Releases, downloaded via gh-proxy or directly)
  while read -r sha fn; do
    [ -n "$fn" ] || continue
    if [ -f "$WH/$fn" ] && echo "$sha  $WH/$fn" | sha256sum -c --status 2>/dev/null; then
      log "wheel already present: $fn"
      continue
    fi
    pkg="${fn%%-*}"
    urlenc="${fn//+/%2B}"
    idx="https://pypi.riseproject.dev/simple/$pkg/"
    href="$(curl -fsSL --connect-timeout 20 "$idx" \
      | grep -oE "href=\"[^\"]*${urlenc}[^\"]*\"" | head -1 | sed 's/href="//;s/"$//')"
    [ -n "$href" ] || die "not found in the RISE index: $fn (index: $idx)"
    href="${href%%#*}"
    log "downloading wheel: $fn"
    curl -fSL --retry 3 --connect-timeout 20 -o "$WH/$fn" "$(gh_url "$href")"
    echo "$sha  $WH/$fn" | sha256sum -c --status || die "sha256 mismatch: $fn (expected $sha)"
  done < <(sed 's/[[:space:]]*$//' "$ASSET_SHA" | grep -v '^#' | grep -v '^$')
  log "wheelhouse ready: $(ls "$WH" | wc -l) wheel(s)"

fi

log "fetch finished"
