#!/usr/bin/env bash
# Stage 1: fetch sources only. Clones the official repositories into work/src (never committed); no patching.
#   REF may be a tag, branch or commit sha; it is recorded under work/src-refs/ to decide on re-fetch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd git
mkdir -p "$SRC_DIR"

clone_ref() { # <name> <url> <ref> <dst>
  local name="$1" url="$2" ref="$3" dst="$4" err attempt
  # 1) shallow clone by tag/branch first; retry transient mirror failures, but only
  #    after confirming the ref actually exists, otherwise fall through to the commit path
  for attempt in 1 2 3; do
    rm -rf "$dst"
    if err="$(run_git clone --depth 1 --branch "$ref" "$url" "$dst" 2>&1)"; then
      git -C "$dst" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref" >/dev/null 2>&1 || true
      return 0
    fi
    if ! run_git ls-remote --exit-code --tags --heads "$url" "$ref" >/dev/null 2>&1; then
      break          # ref really is not a tag/branch -> commit path
    fi
    warn "  [$name] clone failed (attempt $attempt/3, ref exists): $(printf '%s' "$err" | tail -1)"
    sleep $((attempt * 3))
  done
  # 2) fall back to fetching an arbitrary commit
  warn "  [$name] '$ref' is not a tag or branch, trying to fetch it as a commit"
  rm -rf "$dst"
  mkdir -p "$dst"
  git -C "$dst" init -q
  git -C "$dst" remote add origin "$url"
  if run_git -C "$dst" fetch --depth 1 origin "$ref" >/dev/null 2>&1; then
    git -C "$dst" checkout -q FETCH_HEAD
    return 0
  fi
  die "cannot fetch $name @ $ref (not a tag, branch or commit)"
}

fetch_repo() { # <name> <url> <ref>
  local name="$1"
  local url="$2"
  local ref="$3"
  local dst="$SRC_DIR/$name"
  local want="$ref"
  local cur=""
  local marker="$WORK_DIR/src-refs/$name"     # kept outside the work tree so git clean cannot remove it
  mkdir -p "$WORK_DIR/src-refs"
  [ -f "$marker" ] && cur="$(cat "$marker")"
  if [ -d "$dst/.git" ] && [ "$cur" = "$want" ]; then
    log "  [$name] already present: $want ($(git -C "$dst" rev-parse --short HEAD))"
    return 0
  fi
  rm -rf "$dst"
  log "  [$name] fetching $url @ $ref"
  clone_ref "$name" "$url" "$ref" "$dst"
  echo "$want" > "$marker"
  log "  [$name] done ($(git -C "$dst" rev-parse --short HEAD))"
}

# PyPI sdist component: pyluwen has no public git tag, so the sdist is used as the source
fetch_pypi() { # <name> <version>
  local name="$1"
  local ver="$2"
  local dst="$SRC_DIR/$name"
  local marker="$WORK_DIR/src-refs/$name"
  local pristine="$WORK_DIR/src-pristine"
  mkdir -p "$pristine"
  if [ -d "$dst" ] && [ "$(cat "$marker" 2>/dev/null)" = "pypi:$ver" ]; then
    log "  [$name] already present: pypi:$ver"
    return 0
  fi
  rm -rf "$dst"; mkdir -p "$dst"
  log "  [$name] downloading PyPI sdist $ver"
  local tgz url
  tgz="$pristine/$name-$ver.tar.gz"
  if url="$(pypi_sdist_url "$name" "$ver")" && [ -n "$url" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$tgz" "$url" >/dev/null 2>&1 \
      || die "download failed: $url"
  else
    warn "  [$name] the PyPI JSON API did not answer, falling back to pip download"
    python3 -m pip download --no-deps --no-binary :all: -d "$pristine" "$name==$ver" >/dev/null 2>&1 \
      || die "download failed: $name==$ver"
    tgz="$(ls "$pristine/$name-$ver".tar.gz 2>/dev/null | head -1)"
  fi
  [ -n "$tgz" ] && [ -f "$tgz" ] || die "sdist not found: $name-$ver.tar.gz"
  tar xzf "$tgz" -C "$dst" --strip-components=1
  mkdir -p "$WORK_DIR/src-refs"
  echo "pypi:$ver" > "$marker"
  log "  [$name] done (pypi:$ver)"
}

# tt-umd version: aligned with the tools metadata by default; --tt-umd-ref overrides it
TT_SMI_V="${TT_SMI_REF#v}"; TT_FLASH_V="${TT_FLASH_REF#v}"; TT_TOPOLOGY_V="${TT_TOPOLOGY_REF#v}"
if [ "${TT_UMD_PINNED:-0}" = 1 ]; then
  log "tt-umd pinned explicitly: $TT_UMD_REF (metadata is not followed)"
  UMD_EFF_REF="$TT_UMD_REF"
else
  NATIVE="$(resolve_native_versions "$TT_SMI_V" "$TT_FLASH_V" "$TT_TOPOLOGY_V" || true)"
  UMD_SPEC="$(echo "$NATIVE" | awk -F'\t' '$1=="tt-umd"{print $2}' | head -1)"
  UMD_PKG_VER="$(echo "${UMD_SPEC:-=0.9.12}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  UMD_PKG_VER="${UMD_PKG_VER:-0.9.12}"
  UMD_EFF_REF="v$UMD_PKG_VER"
  if [ "$UMD_EFF_REF" != "$TT_UMD_REF" ]; then
    warn "tt-umd adjusted to $UMD_EFF_REF as required by the tools (manifest/flag said $TT_UMD_REF; use --tt-umd-ref to force)"
  fi
fi

log "fetching official sources into $SRC_DIR (not part of the git repository)"
fetch_repo tt-kmd      https://github.com/tenstorrent/tt-kmd.git      "$TT_KMD_REF"
fetch_repo tt-umd      https://github.com/tenstorrent/tt-umd.git      "$UMD_EFF_REF"
fetch_repo tt-smi      https://github.com/tenstorrent/tt-smi.git      "$TT_SMI_REF"
fetch_repo tt-flash    https://github.com/tenstorrent/tt-flash.git    "$TT_FLASH_REF"
fetch_repo tt-topology https://github.com/tenstorrent/tt-topology.git "$TT_TOPOLOGY_REF"
# pyluwen: pyo3/abi3 extension used by tt-smi/tt-flash/tt-topology; needs a patch on riscv64
fetch_pypi pyluwen    "$PYLUWEN_REF"

log "Source versions:"
for n in tt-kmd tt-umd tt-smi tt-flash tt-topology pyluwen; do
  printf '  %-14s ref=%-14s %-12s %s\n' "$n" \
    "$(cat "$WORK_DIR/src-refs/$n" 2>/dev/null || echo '?')" \
    "$(git -C "$SRC_DIR/$n" describe --tags 2>/dev/null || echo '(no tag)')" \
    "$(git -C "$SRC_DIR/$n" rev-parse --short HEAD 2>/dev/null || echo '?')"
done
log "fetch finished (next: --stage patch, or --no-patch to skip)"
