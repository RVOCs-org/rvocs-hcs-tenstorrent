#!/usr/bin/env bash
# Stage 3: build a wheelhouse for every target Ubuntu / Python version
#   Sources come from work/src (fetched and patched); output goes to work/wheelhouse
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

INSIDE="$SCRIPT_DIR/lib/wheelhouse_inside.sh"
[ -f "$INSIDE" ] || die "missing scripts/lib/wheelhouse_inside.sh"
[ -d "$SRC_DIR/tt-smi" ] || die "sources missing (run --stage fetch first)"

# Patched components (from the patch stage; falls back to reading the series)
if [ -f "$WORK_DIR/patched-components.txt" ]; then
  PATCHED="$(tr '\n' ' ' < "$WORK_DIR/patched-components.txt" | sed 's/[[:space:]]*$//')"
else
  PATCHED=""
  for c in tt-kmd tt-umd tt-smi tt-flash tt-topology; do
    has_patches "$c" && PATCHED="$PATCHED $c"
  done
  PATCHED="${PATCHED# }"
fi

strip_v() { echo "${1#v}"; }
TT_SMI_V=$(strip_v "$TT_SMI_REF"); TT_FLASH_V=$(strip_v "$TT_FLASH_REF"); TT_TOPOLOGY_V=$(strip_v "$TT_TOPOLOGY_REF")
UMD_VER="$(git -C "$SRC_DIR/tt-umd" describe --tags 2>/dev/null | sed 's/^v//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
UMD_VER="${UMD_VER:-0.9.12}"
NATIVE="$(resolve_native_versions "$TT_SMI_V" "$TT_FLASH_V" "$TT_TOPOLOGY_V" || true)"
LUWEN_VER="$(echo "$NATIVE" | awk -F'\t' '$1=="pyluwen"{print $2}' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
LUWEN_VER="${LUWEN_VER:-0.10.0}"
log "tools: tt-smi=$TT_SMI_V tt-flash=$TT_FLASH_V tt-topology=$TT_TOPOLOGY_V  tt-umd=$UMD_VER  pyluwen=$LUWEN_VER"
log "patched components: ${PATCHED:-(none)}"

# pyluwen version required by tt-topology (differs from tt-smi/tt-flash, so both need an abi3 wheel)
TP_LU="$(python3 - "$TT_TOPOLOGY_V" <<'PY'
import json, sys, urllib.request, re
try:
    with urllib.request.urlopen(f"https://pypi.org/pypi/tt-topology/{sys.argv[1]}/json", timeout=30) as r:
        for r in (json.load(r)["info"]["requires_dist"] or []):
            m = re.match(r"^\s*pyluwen\s*([<>=~!].*)?$", r)
            if m:
                v = re.findall(r"[0-9]+\.[0-9]+\.[0-9]+", m.group(1) or "")
                if v: print(v[0]); break
except Exception: pass
PY
)"
TP_LU="${TP_LU:-0.8.5}"

# ---------------------------------------------------------------- abi3 wheel
# pyo3/abi3 extensions (pyluwen) must be built in an image with a standard host triple and cargo >= 1.85; see lib/abi3_wheels.sh
ABI3_DIR=""
ABI3_IMAGE="${ABI3_BUILD_IMAGE:-}"
if [ -z "$ABI3_IMAGE" ] && [ "$ARCH" = riscv64 ]; then ABI3_IMAGE="debian:13"; fi
if [ -n "$ABI3_IMAGE" ]; then
  ABI3_DIR="$WORK_DIR/wheelhouse/abi3-$ARCH"
  mkdir -p "$ABI3_DIR"
  need=0
  for v in "$LUWEN_VER" "$TP_LU"; do
    find "$ABI3_DIR" -name "pyluwen-$v-*.whl" 2>/dev/null | grep -q . || need=1
  done
  if [ "$need" = 1 ] || [ "${ABI3_REBUILD:-0}" = 1 ]; then
    specs=""; for v in "$LUWEN_VER" "$TP_LU"; do specs="$specs pyluwen==$v"; done
    # crates index: official by default (works here); set CRATES_MIRROR to override
    mirror="${CRATES_MIRROR:-}"
    dmirror="${DEBIAN_MIRROR:-}"; [ -z "$dmirror" ] && [ "${PROXY:-0}" = 1 ] && dmirror="http://mirrors.tuna.tsinghua.edu.cn/debian"
    cache="$WORK_DIR/.cache/abi3"
    mkdir -p "$cache/apt" "$cache/wheels"
    log "building abi3 wheels($ABI3_IMAGE):$specs"
    docker run --rm \
      -v "$ABI3_DIR:/out" -v "$SCRIPT_DIR/lib/abi3_wheels.sh:/abi3.sh:ro" \
      -v "$cache/apt:/var/cache/apt/archives" -v "$cache/wheels:/cache" \
      -v "$SRC_DIR:/src:ro" \
      -e OUT=/out -e PYLUWEN_SPECS="$specs" -e CRATES_MIRROR="$mirror" -e DEBIAN_MIRROR="$dmirror" -e CACHE=/cache -e SRC=/src -e PROTOC=/usr/bin/protoc \
      -e PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple}" \
      "$ABI3_IMAGE" bash /abi3.sh || die "abi3 wheel build failed($ABI3_IMAGE)"
  else
    log "abi3 wheels already present, skipping (ABI3_REBUILD=1 forces a rebuild)"
  fi
  log "  abi3: $(find "$ABI3_DIR" -name '*.whl' -printf '%f ' 2>/dev/null)"
fi

BACKEND="${WHEELS_BACKEND:-auto}"
if [ "$BACKEND" = auto ]; then
  if docker info >/dev/null 2>&1; then BACKEND=docker; else BACKEND=uv; warn "docker unavailable, using the uv backend"; fi
fi
log "wheelhouse backend: $BACKEND"

ensure_uv() {
  command -v uv >/dev/null 2>&1 && return 0
  [ -x "$HOME/.local/bin/uv" ] && { export PATH="$HOME/.local/bin:$PATH"; return 0; }
  log "installing uv (user level)"
  curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv-install.sh && sh /tmp/uv-install.sh >/dev/null 2>&1 || die "uv installation failed"
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null || die "uv is not available"
}

for t in $TARGETS; do
  py=$(ubuntu_pyver "$t"); tag=$(pyver_tag "$py"); out="$WORK_DIR/wheelhouse/$tag"
  if [ "${WHEELS_REUSE:-0}" = 1 ] && [ -n "$(find "$out" -name '*.whl' 2>/dev/null | head -1)" ]; then
    log "  WHEELS_REUSE=1:reusing $(find "$out" -name '*.whl' | wc -l) existing wheels"
  else
    rm -rf "$out"
  fi
  mkdir -p "$out"
  log "=== $t (python $py) -> wheelhouse/$tag ==="

  if [ "$BACKEND" = docker ]; then
    abi3_args=()
    [ -n "$ABI3_DIR" ] && abi3_args+=(-v "$ABI3_DIR:/abi3:ro" -e ABI3=/abi3)
    docker run --rm -v "$out:/out" -v "$SRC_DIR:/src:ro" -v "$INSIDE:/inside.sh:ro" \
      "${abi3_args[@]}" \
      -e OUT=/out -e PY=python3 -e SRC=/src -e PATCHED="$PATCHED" \
      -e TT_SMI_V="$TT_SMI_V" -e TT_FLASH_V="$TT_FLASH_V" -e TT_TOPOLOGY_V="$TT_TOPOLOGY_V" \
      -e UMD_VER="$UMD_VER" -e LUWEN_VER="$LUWEN_VER" \
      -e PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple}" \
      "${UBUNTU_IMAGE_PREFIX:-}ubuntu:$t" bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq python3 python3-dev python3-pip build-essential cmake ninja-build \
              pkg-config git curl ca-certificates xz-utils libhwloc-dev libnuma-dev \
              libjpeg-dev zlib1g-dev libpng-dev libtiff-dev libfreetype-dev liblcms2-dev libwebp-dev \
              >/dev/null
        bash /inside.sh'
  else
    ensure_uv
    venv="$WORK_DIR/venvs/$tag"
    [ -x "$venv/bin/python" ] || { log "  creating uv venv (python $py)"; uv venv --python "$py" "$venv" >/dev/null 2>&1 || die "uv venv failed"; }
    log "  venv: $("$venv/bin/python" -V 2>&1)"
    uv pip install --python "$venv/bin/python" -q pip wheel setuptools cmake ninja >/dev/null 2>&1 || \
      warn "pip/cmake/ninja install warning (ignore when nothing is built from source)"
    OUT="$out" PY="$venv/bin/python" SRC="$SRC_DIR" PATCHED="$PATCHED" ABI3="${ABI3_DIR:-}" \
      TT_SMI_V="$TT_SMI_V" TT_FLASH_V="$TT_FLASH_V" TT_TOPOLOGY_V="$TT_TOPOLOGY_V" \
      UMD_VER="$UMD_VER" LUWEN_VER="$LUWEN_VER" bash "$INSIDE"
  fi

  n=$(find "$out" -name '*.whl' | wc -l)
  log "  => $n wheel(s)"
  [ "$n" -ge 8 ] || die "$t  wheelhouse has an unexpected number of wheels: $n"
done

log "wheels stage finished"
