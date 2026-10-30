#!/usr/bin/env bash
# Stage 2 (riscv64 only): prepare the build workspace
#   self-contained source trees -> apply patches/riscv64 -> SFPI package pre-flight -> place offline assets
#
# About the source trees (A1): when upstream/* are git submodules, their .git file points into .git/modules of the superproject
# through a relative path. A plain cp -a into work/ changes the depth and breaks it, which makes
#   1) git apply on the host fail with "fatal: not a git repository" (patches cannot be applied)
#   2) uv pip install -e . inside the container fail to find a version (setuptools-scm)
# A local clone is therefore used to produce self-contained source trees:
#   - git clone --local: objects are hard-linked and self-contained (never --shared, which adds a path dependency)
#   - the clone keeps tags so setuptools-scm / cmake version.cmake resolve the right version
#   - initialized nested submodules are copied from upstream and their .git rewritten to a path inside the tree
#     (still resolvable after a cp -a inside the container)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PDIR="$REPO_ROOT/patches/$ARCH"
mkdir -p "$PDIR"
[ -d "$PDIR" ] || die "$PDIR not found (the patch layer lives in patches/$ARCH on master)"

# ---------------------------------------------------------------- source trees
log "preparing the build workspace: $WORK_DIR"
if [ -d "$(work_ttmetal)" ] || [ -d "$(work_plugin)" ]; then
  warn "the existing workspace ($(work_ctx) etc.) will be removed and rebuilt: manual source edits are lost."
  warn "to keep changes, export them as a patch first: git -C $(work_ttmetal) diff -- <file> > patches/$ARCH/tt-metal/10NN-xxx.patch"
fi

materialize() { # materialize <upstream repo> <target dir>
  local src="$1"
  local dst="$2"
  local sha url
  [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] \
    || die "submodule missing: $src (run --stage fetch, or: git submodule update --init $src)"
  sha=$(git -C "$src" rev-parse HEAD)
  rm -rf "$dst"
  git clone --local --quiet --no-checkout "$src" "$dst"
  git -C "$dst" checkout --quiet --detach "$sha"
  url=$(git -C "$src" config --get remote.origin.url 2>/dev/null || true)
  case "$url" in
    http*|git@*|ssh*) git -C "$dst" remote set-url origin "$url" ;;
  esac
}

attach_submodules() { # attach_submodules <upstream repo> <target dir>
  local src="$1" dst="$2" srcgit key name path
  srcgit=$(git -C "$src" rev-parse --absolute-git-dir)
  while read -r key path; do
    [ -n "${path:-}" ] || continue
    name="${key#submodule.}"
    name="${name%.path}"
    [ -d "$src/$path" ] || continue
    [ -n "$(ls -A "$src/$path" 2>/dev/null)" ] || continue   # skip when not initialized in the source
    rm -rf "${dst:?}/$path"
    mkdir -p "$(dirname "$dst/$path")"
    cp -a "$src/$path" "$dst/$path"
    if [ -d "$srcgit/modules/$name" ]; then
      mkdir -p "$dst/.git/modules/$name"
      cp -a "$srcgit/modules/$name/." "$dst/.git/modules/$name/"
      printf 'gitdir: %s\n' "$(realpath -m --relative-to="$dst/$path" "$dst/.git/modules/$name")" \
        > "$dst/$path/.git"
    fi
    log "    attached submodule: $path"
  done < <(git -C "$src" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
}

log "creating the workspace source trees (self-contained clones, not cp -a of submodules) ..."
materialize "$REPO_ROOT/upstream/tt-inference-server" "$(work_ctx)"
materialize "$REPO_ROOT/upstream/tt-metal"            "$(work_ttmetal)"
materialize "$REPO_ROOT/upstream/vllm-tt-plugin"      "$(work_plugin)"
materialize "$REPO_ROOT/upstream/tt-smi"              "$(work_ttsmi)"
materialize "$REPO_ROOT/upstream/sfpi"                "$(work_sfpi)"

log "  copying initialized nested submodules ..."
attach_submodules "$REPO_ROOT/upstream/tt-metal" "$(work_ttmetal)"
attach_submodules "$REPO_ROOT/upstream/sfpi"     "$(work_sfpi)"

# ---------------------------------------------------------------- apply patches
apply_series() { # apply_series <target tree> <patch dir name>
  local tree="$1" name="$2" s="$PDIR/$2/series"
  [ -f "$s" ] || die "missing series: $s"
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    log "  [$name] applying patch: $p"
    git -C "$tree" apply --check "$PDIR/$name/$p" || die "patch does not apply cleanly: $p (did the upstream version change?)"
    git -C "$tree" apply        "$PDIR/$name/$p"
  done < "$s"
}
apply_series "$(work_ttmetal)" tt-metal
apply_series "$(work_plugin)"  vllm-tt-plugin

# ---------------------------------------------------------------- SFPI prebuilt package
# The expected file name is computed by sfpi-info.sh from the host arch, OS family and version pin,
# and matches what tt-metal's CMake consumes (hw/CMakeLists.txt only checks that the file exists).
sfpi_expect_filename() {
  ( cd "$(work_ttmetal)" && bash tt_metal/sfpi-info.sh CMAKE txz 2>/dev/null ) \
    | sed -n 's/^set(SFPI_filename "\(.*\)")$/\1/p' | head -1
}

sfpi_preflight() { # sfpi_preflight <txz path>; returns 0 when it passes
  local txz="$1" base expect tmp gxx
  base=$(basename "$txz")
  [ -s "$txz" ] || { warn "SFPI package missing or empty: $txz"; return 1; }

  expect=$(sfpi_expect_filename)
  if [ -n "$expect" ] && [ "$base" != "$expect" ]; then
    warn "SFPI package name does not match this host: have=$base expect=$expect"
    warn "(host arch / OS family / SFPI version pin mismatch, so tt-metal would ignore this file)"
    return 1
  fi

  if [ -f "$txz.sha256" ]; then
    ( cd "$(dirname "$txz")" && sha256sum -c "$(basename "$txz").sha256" --status ) \
      || { warn "SFPI package sha256 mismatch: $base"; return 1; }
  fi

  tmp=$(mktemp -d)
  if ! tar -xJf "$txz" -C "$tmp" 2>/dev/null; then
    warn "failed to extract the SFPI package: $base"; rm -rf "$tmp"; return 1
  fi
  gxx="$tmp/sfpi/compiler/bin/riscv-tt-elf-g++"
  if [ ! -x "$gxx" ]; then
    warn "riscv-tt-elf-g++ is missing from the package: $base"; rm -rf "$tmp"; return 1
  fi
  # the next two steps verify both the host arch and a new enough host glibc
  if ! "$gxx" --version >/dev/null 2>&1; then
    warn "the SFPI compiler cannot run here (arch or glibc mismatch, host glibc: $(ldd --version | head -1 | awk '{print $NF}'))"
    rm -rf "$tmp"; return 1
  fi
  printf 'extern "C" void kernel_main() {}\n' > "$tmp/k.cpp"
  if ! "$gxx" -mcpu=tt-bh -mabi=ilp32 -c "$tmp/k.cpp" -o "$tmp/k.o" >/dev/null 2>&1; then
    warn "SFPI compiler smoke build failed (-mcpu=tt-bh -mabi=ilp32)"; rm -rf "$tmp"; return 1
  fi
  log "SFPI prebuilt package passed the pre-flight check: $base ($("$gxx" --version | head -1))"
  rm -rf "$tmp"
  return 0
}

mkdir -p "$(work_sfpipre)"
# Remove a package left over from a previous run, otherwise the image stage would reuse it when falling back to a source build
rm -f "$(work_sfpipre)"/*.txz "$(work_sfpipre)"/*.sha256
SFPI_TXZ=""
SFPI_SRC_DESC=""
if [ "${NO_SFPI_PREBUILT:-0}" = 1 ]; then
  log "--no-sfpi-prebuilt given: no prebuilt package will be used"
elif [ -n "$SFPI_PREBUILT_DIR" ] && compgen -G "$SFPI_PREBUILT_DIR/*.txz" >/dev/null; then
  SFPI_TXZ=$(ls -1 "$SFPI_PREBUILT_DIR"/*.txz | head -1)
  SFPI_SRC_DESC="--sfpi-prebuilt"
elif compgen -G "$(asset_sfpi_dir)/*.txz" >/dev/null; then
  SFPI_TXZ=$(ls -1 "$(asset_sfpi_dir)"/*.txz | head -1)
  SFPI_SRC_DESC="bundled in the repo (assets/$ARCH)"
elif compgen -G "$REPO_ROOT/assets/sfpi-prebuilt/*.txz" >/dev/null; then
  SFPI_TXZ=$(ls -1 "$REPO_ROOT/assets/sfpi-prebuilt"/*.txz | head -1)
  SFPI_SRC_DESC="bundled in the repo"
fi

if [ -n "$SFPI_TXZ" ]; then
  log "checking the SFPI prebuilt package ($SFPI_SRC_DESC): $(basename "$SFPI_TXZ")"
  if sfpi_preflight "$SFPI_TXZ"; then
    cp "$SFPI_TXZ" "$(work_sfpipre)/"
    if [ -f "$SFPI_TXZ.sha256" ]; then
      cp "$SFPI_TXZ.sha256" "$(work_sfpipre)/"
    fi
  else
    warn "the prebuilt package is unusable here -> falling back to a source build in the container (~90 minutes); use --sfpi-prebuilt DIR for another one"
    SFPI_TXZ=""
  fi
fi
if [ -z "$SFPI_TXZ" ] && [ "$ARCH" != riscv64 ]; then
  # x86_64/aarch64 normally stage the official package in 01-fetch; without it the
  # CMake configure step tries its own download and finally a source build.
  log "SFPI: no staged package for $ARCH -> tt-metal's CMake will download it (source build as the last resort)"
elif [ -z "$SFPI_TXZ" ] && [ "${NO_SFPI_PREBUILT:-0}" != 1 ]; then
  [ -n "$SFPI_SRC_DESC" ] || warn "no SFPI prebuilt package found -> the toolchain will be built from source (~90 minutes)"
fi

# ---------------------------------------------------------------- place offline assets
log "placing offline assets ..."
mkdir -p "$(work_ttmetal)/.cpmcache/cpm"
cp "$REPO_ROOT/assets/CPM_0.40.2.cmake" "$(work_ttmetal)/.cpmcache/cpm/"

mkdir -p "$(work_ctx)/vendor"
cp "$REPO_ROOT/assets/vllm-common.txt" "$(work_ctx)/vendor/"

WH="$WORK_DIR/assets/wheelhouse"
mkdir -p "$(work_ctx)/wheelhouse"
if [ -n "$(ls "$WH"/*.whl 2>/dev/null)" ]; then
  cp "$WH"/*.whl "$(work_ctx)/wheelhouse/"
  log "wheelhouse: $(ls "$WH"/*.whl | wc -l) wheel(s) staged"
else
  # x86_64/aarch64 pull these from PyPI inside the build; the Dockerfile handles both
  log "no local wheelhouse staged ($ARCH uses PyPI for torch/numpy/pandas)"
fi

RUSTUP="$WORK_DIR/assets/files/rustup-init"
[ -x "$RUSTUP" ] || die "missing rustup-init (run --stage fetch first)"
mkdir -p "$(work_rustup)"
cp "$RUSTUP" "$(work_rustup)/rustup-init"

# ---------------------------------------------------------------- model_spec.json
# Produced by the official flow (gitignored upstream), so it must be generated explicitly for the runtime stage to COPY.
# Official entry point: scripts/release/export_model_spec.py; its JSON output matches the tracked
# release_model_spec.json (verified by sha256).
CTX="$(work_ctx)"
if [ ! -s "$CTX/model_spec.json" ]; then
  if ( cd "$CTX" && python3 scripts/release/export_model_spec.py --json-only ) >/dev/null 2>&1; then
    cp "$CTX/release_model_spec.json" "$CTX/model_spec.json"
    log "model_spec.json exported with the official generator"
  else
    warn "official generator unavailable, falling back to the tracked release_model_spec.json"
    cp "$CTX/release_model_spec.json" "$CTX/model_spec.json"
  fi
fi
[ -s "$CTX/model_spec.json" ] || die "failed to produce model_spec.json (the runtime stage COPYs it)"
log "model_spec.json: $(wc -c < "$CTX/model_spec.json") bytes"

# Trim the main context: source trees are injected as named contexts, not transferred in the main context
DI="$CTX/.dockerignore"
if ! grep -q 'source-build-contexts' "$DI" 2>/dev/null; then
  cat >> "$DI" <<'EOF'

# source-build-contexts: sources are injected via --build-context named contexts, not the main context
tt-metal-src
vllm-tt-plugin-src
tt-smi-src
sfpi-src
vendor
EOF
fi

log "workdir finished: $CTX"
