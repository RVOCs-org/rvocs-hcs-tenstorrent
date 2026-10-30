#!/usr/bin/env bash
# Shared helpers, sourced by the stage scripts.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
SRC_DIR="$WORK_DIR/src"                 # official sources fetched at build time (never committed)
DIST_DIR="$REPO_ROOT/dist"              # build artifacts (never committed)
PATCH_DIR="$REPO_ROOT/patches"
LOG_DIR="$WORK_DIR/logs"
# Repository version: VERSION is the single source of truth (also used for
# artifact naming). Override with TTI_VERSION when needed.
TTI_VERSION="${TTI_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo v0.1.0)}"

ARCH="${ARCH:-$(uname -m)}"
PROXY_MODE="${PROXY_MODE:-auto}"
PROXY="${PROXY:-}"
TARGETS="${UBUNTU_TARGETS:-${TARGETS:-}}"     # Ubuntu release list (see build.sh for the validation)
TOOLS="${TOOLS:-tt-smi tt-flash tt-topology}"
SKIP_PATCH="${SKIP_PATCH:-0}"           # 1 = do not apply any patch
KERNELS="${KERNELS:-}"
# ---- artifact naming -------------------------------------------------------
#   dist/rvocs-tt-deps_<version>_<debarch>.tar.zst   (+ .sha256)
#   dist/rvocs-tt-deps_<version>_<debarch>.deb       (+ .sha256)
# <version> is the repository version (VERSION); <debarch> is the Debian name.
PKG_PREFIX="${PKG_PREFIX:-rvocs-tt-deps}"
BUNDLE_VER="${BUNDLE_VER:-$TTI_VERSION}"
# Debian versions must start with a digit, while VERSION carries the git tag form
# ("v0.1.0"). Normalise once here so the .deb control file, the artifact names and
# dist/VERSION all agree; TTI_VERSION keeps the tag for display.
BUNDLE_VER="${BUNDLE_VER#v}"
case "$BUNDLE_VER" in
  [0-9]*) : ;;
  *) die "invalid bundle version '$BUNDLE_VER' (Debian requires a leading digit; set TTI_VERSION or --bundle-ver)" ;;
esac
arch_deb() { # Debian architecture name for a uname-style arch
  case "$1" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    riscv64)        echo riscv64 ;;
    *)              echo "$1" ;;
  esac
}

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# ---------------------------------------------------------------- manifest
# Read a component ref: ref_by_arch.<arch> first, then ref, then the built-in default
manifest_ref() { # <component> <fallback>
  local comp="$1" fallback="$2" mf="$REPO_ROOT/manifest.yaml"
  if [ ! -f "$mf" ]; then echo "$fallback"; return 0; fi
  python3 - "$mf" "$comp" "$ARCH" "$fallback" <<'PY'
import sys
mf, comp, arch, fallback = sys.argv[1:5]
in_src = in_comp = in_arch = False
ref = arch_ref = None
for ln in open(mf).read().splitlines():
    if not in_src:
        if ln.strip() == "sources:":
            in_src = True
        continue
    if ln and not ln.startswith(" "):        # left the sources block
        break
    stripped = ln.strip()
    if ln.startswith("  ") and not ln.startswith("    ") and stripped.endswith(":"):
        in_comp = (stripped == comp + ":")
        in_arch = False
        continue
    if not in_comp or not stripped or stripped.startswith("#"):
        continue
    if stripped.startswith("ref_by_arch:"):
        in_arch = True
        continue
    if in_arch:
        if ln.startswith("      ") and ":" in stripped:
            k, v = stripped.split(":", 1)
            if k.strip() == arch:
                arch_ref = v.strip()
            continue
        if not ln.startswith("      "):
            in_arch = False
    if stripped.startswith("ref:"):
        ref = stripped.split(":", 1)[1].strip()
print(arch_ref or ref or fallback)
PY
}

TT_KMD_REF="${TT_KMD_REF:-$(manifest_ref tt-kmd ttkmd-2.11.0)}"
TT_UMD_REF="${TT_UMD_REF:-$(manifest_ref tt-umd v0.9.14)}"
TT_SMI_REF="${TT_SMI_REF:-$(manifest_ref tt-smi v6.8.0)}"
TT_FLASH_REF="${TT_FLASH_REF:-$(manifest_ref tt-flash v4.1.0)}"
TT_TOPOLOGY_REF="${TT_TOPOLOGY_REF:-$(manifest_ref tt-topology v1.2.20)}"
TT_UMD_PINNED="${TT_UMD_PINNED:-0}"
# pyluwen has no public git tag, so its source comes from the PyPI sdist (a version, not a ref)
PYLUWEN_REF="${PYLUWEN_REF:-$(manifest_ref pyluwen 0.10.0)}"

# ---------------------------------------------------------------- proxy / git
resolve_proxy() {
  [ -n "$PROXY" ] && return 0
  case "$PROXY_MODE" in
    cn)     PROXY=1 ;;
    direct) PROXY=0 ;;
    auto)   if curl -fsSI -m 8 https://github.com >/dev/null 2>&1; then PROXY=0; else PROXY=1; warn "github is unreachable, enabling mirror mode"; fi ;;
    *) die "unknown --proxy: $PROXY_MODE" ;;
  esac
  if [ "$PROXY" = 1 ]; then
    export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
  fi
}

pypi_sdist_url() { # <name> <version> -> prints the sdist URL, exit 1 when unknown
  # Resolve through the PyPI JSON API instead of "pip download --no-binary :all:":
  # pip has to *build metadata* for these sdists (pyluwen uses the maturin backend),
  # which drags in a Rust toolchain and the build requirements just to fetch a file.
  python3 - "$1" "$2" <<'PY'
import json, sys, urllib.request
name, ver = sys.argv[1], sys.argv[2]
for base in ("https://pypi.org", "https://pypi.tuna.tsinghua.edu.cn"):
    for path in (f"/pypi/{name}/{ver}/json", f"/pypi/{name}/json"):
        try:
            with urllib.request.urlopen(base + path, timeout=25) as r:
                data = json.load(r)
        except Exception:
            continue
        files = data.get("urls") or data.get("releases", {}).get(ver, [])
        for f in files:
            if f.get("filename", "").endswith((".tar.gz", ".zip")):
                print(f["url"])
                sys.exit(0)
sys.exit(1)
PY
}

run_git() {
  if [ "${PROXY:-0}" = 1 ]; then
    git -c "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" "$@"
  else
    git "$@"
  fi
}

# ---------------------------------------------------------------- targets
default_targets() {
  case "$ARCH" in
    riscv64) echo "26.04" ;;
    x86_64)  echo "22.04 24.04 26.04" ;;
    *)       echo "$(lsb_release -rs 2>/dev/null || echo 26.04)" ;;
  esac
}
ubuntu_pyver() {
  case "$1" in
    22.04) echo "3.10" ;; 24.04) echo "3.12" ;; 26.04) echo "3.14" ;;
    *) die "unsupported Ubuntu version: $1" ;;
  esac
}
pyver_tag() { echo "py$(echo "$1" | tr -d '.')"; }

resolve_native_versions() {
  local smi="$1"
  local flash="$2"
  local topo="$3"
  python3 - "$smi" "$flash" "$topo" <<'PY'
import json, sys, urllib.request, re
def reqs(pkg, ver):
    with urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/{ver}/json", timeout=30) as r:
        return json.load(r)["info"]["requires_dist"] or []
out = {}
for pkg, ver in (("tt-smi", sys.argv[1]), ("tt-flash", sys.argv[2]), ("tt-topology", sys.argv[3])):
    try: rs = reqs(pkg, ver)
    except Exception: continue
    for r in rs:
        m = re.match(r"^\s*(tt[-_]umd|pyluwen)\s*([<>=~!].*)?$", r)
        if m:
            name = m.group(1).replace("_", "-")
            out.setdefault(name, set()).add((m.group(2) or "").strip())
for k, v in out.items():
    print(k + "\t" + ",".join(sorted(v)))
PY
}

# ---------------------------------------------------------------- patches
# Patch directories for a component, applied in order: common -> <arch>
patch_dirs_for() { # <component>
  local comp="$1" d
  for d in "$PATCH_DIR/common/$comp" "$PATCH_DIR/$ARCH/$comp"; do
    [ -d "$d" ] && echo "$d"
  done
  # Always succeed: callers use dirs="$(patch_dirs_for ...)" under `set -e`, and the
  # trailing [ -d ] test used to make the function return 1 when the arch directory
  # was absent (e.g. pyluwen has no x86_64 patches) -- which killed the patch stage
  # silently, with no error message at all.
  return 0
}

patch_dirs_has_entries() { # <dir>
  local d="$1"
  [ -f "$d/series" ] || return 1
  grep -qvE '^[[:space:]]*(#|$)' "$d/series"
}

has_patches() { # <component>: common or this arch has a non-empty series
  local comp="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    patch_dirs_has_entries "$d" && return 0
  done < <(patch_dirs_for "$comp")
  return 1
}
