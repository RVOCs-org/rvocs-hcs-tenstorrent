#!/usr/bin/env bash
# Build a wheelhouse inside a given Python environment
#   - patched components are built from work/src (already patched)
#   - a version missing from PyPI (branch/commit/unreleased tag) is also built from source
#   - everything else prefers the PyPI wheel
#   - the three tools resolve dependencies separately (tt-smi/tt-flash need pyluwen ~0.10, tt-topology ~0.8.5)
# Environment: OUT PY SRC PATCHED TT_SMI_V TT_FLASH_V TT_TOPOLOGY_V UMD_VER LUWEN_VER
set -euo pipefail
OUT="${OUT:?}"; PY="${PY:-python3}"; SRC="${SRC:?}"; PATCHED="${PATCHED:-}"; ABI3="${ABI3:-}"
mkdir -p "$OUT"; LOCAL="$(mktemp -d)"
trap 'rm -rf "$LOCAL"' EXIT

# abi3 wheels (built in another image, e.g. pyluwen) take precedence over sdist builds
ABI3_ARGS=()
if [ -n "$ABI3" ] && [ -d "$ABI3" ]; then
  ABI3_ARGS=(--find-links "$ABI3")
  echo "[info] abi3 wheels from $ABI3 ($(find "$ABI3" -name '*.whl' | wc -l) wheel(s))"
fi

have_local() { ls "$OUT/$1"-*.whl >/dev/null 2>&1; }
have_binary() { "$PY" -m pip download --no-deps --dest "/tmp/probe_$$" --only-binary=:all: "$1" >/dev/null 2>&1; }
on_pypi()     { "$PY" -m pip download --no-deps --dest "/tmp/probe_$$" "$1" >/dev/null 2>&1; }

need_local() { # <component> <spec>
  case " $PATCHED " in *" $1 "*) return 0 ;; esac      # patched: must build from source
  on_pypi "$2" || return 0                              # version absent from PyPI: build from source
  return 1
}

# Rust: prefer the distro package; rustup has no riscv64 host build (maturin fails outright)
# crates.io is slow/unreliable from CN; cargo supports a sparse mirror
configure_crates_mirror() {
  local mirror="${CRATES_MIRROR:-}"
  [ -n "$mirror" ] || return 0
  mkdir -p "$HOME/.cargo"
  if ! grep -q 'replace-with' "$HOME/.cargo/config.toml" 2>/dev/null; then
    cat >> "$HOME/.cargo/config.toml" <<EOF
[source.crates-io]
replace-with = "mirror"
[source.mirror]
registry = "sparse+$mirror"
EOF
    echo "[info] crates mirror: sparse+$mirror"
  fi
}

ensure_rust() {
  command -v cargo >/dev/null 2>&1 && { echo "[info] using existing Rust: $(rustc --version 2>/dev/null)"; configure_crates_mirror; return 0; }
  echo "[info] Rust is required to build native extensions from source"
  if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null 2>&1; then
    echo "[info] apt-get install rustc cargo"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rustc cargo >/dev/null 2>&1 || true
  fi
  if command -v cargo >/dev/null 2>&1; then
    echo "[info] using the system Rust: $(rustc --version 2>/dev/null)"
    configure_crates_mirror
    return 0
  fi
  echo "[info] falling back to rustup"
  if ! command -v rustup >/dev/null 2>&1; then
    curl -sSf https://sh.rustup.rs -o /tmp/rustup.sh 2>/dev/null || return 1
    sh /tmp/rustup.sh -y --profile minimal >/dev/null 2>&1 || true
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  command -v cargo >/dev/null 2>&1
}

build_local() { # <component>
  local c="$1"
  [ -d "$SRC/$c" ] || { echo "[error] missing source $SRC/$c"; return 1; }
  echo "[info] building $c from source ($(git -c safe.directory='*' -C "$SRC/$c" describe --tags 2>/dev/null || echo '?'))"

  # CMake pulls dependencies (nanobind and its submodules) over the network at build time;
  # that intermittently fails here, so retry network-class errors up to 3 times with a fresh copy
  local attempt=1 max=3 work rc=1
  while [ "$attempt" -le "$max" ]; do
    work="$(mktemp -d)"
    if ! tar -C "$SRC/$c" -cf - --exclude=.git . 2>/dev/null | tar -C "$work" -xf - 2>/dev/null; then
      echo "[error] failed to copy the sources: $c"; rm -rf "$work"; return 1
    fi
    if "$PY" -m pip wheel --no-deps --wheel-dir "$LOCAL" "$work" >"/tmp/build_$c.log" 2>&1; then
      cp -f "$LOCAL"/*.whl "$OUT"/ 2>/dev/null || true   # persist now so later failures keep it
      rc=0; rm -rf "$work"; break
    fi
    rm -rf "$work"
    if grep -qiE 'Failed to update submodules|Failed to clone|Could not resolve host|Connection (reset|timed out)|CPM|FetchContent|RPC failed|early EOF|SSL' "/tmp/build_$c.log"; then
      echo "[warn] $c attempt $attempt/$max failed (network), $( [ "$attempt" -lt "$max" ] && echo 'retrying' || echo 'giving up' )"
      attempt=$((attempt+1)); sleep 10; continue
    fi
    break
  done
  if [ "$rc" = 0 ]; then echo "[info] $c built successfully"; return 0; fi
  echo "[error] $c build failed"; tail -30 "/tmp/build_$c.log"; return 1
}

"$PY" -m pip install -q --upgrade pip wheel setuptools >/dev/null 2>&1 || true
echo "[info] patched components: ${PATCHED:-(none)}"

# 1) tt-umd
if have_local tt_umd; then
  echo "[info] tt-umd wheel already present, skipping the source build"
elif need_local tt-umd "tt-umd==$UMD_VER" || ! have_binary "tt-umd==$UMD_VER"; then
  build_local tt-umd || exit 1
fi

# 2) tools: build from source when patched or the version is not on PyPI
for spec_pair in "tt-smi:$TT_SMI_V" "tt-flash:$TT_FLASH_V" "tt-topology:$TT_TOPOLOGY_V"; do
  c="${spec_pair%%:*}"; v="${spec_pair##*:}"
  need_local "$c" "$c==$v" && { build_local "$c" || exit 1; }
done

# 3) resolve dependencies per tool
resolve_tool() { # <spec>
  local spec="$1"
  if "$PY" -m pip download --dest "$OUT" --only-binary=:all: \
        "${ABI3_ARGS[@]}" --find-links "$LOCAL" --find-links "$OUT" "$spec" >/tmp/resolve.log 2>&1; then
    echo "[info] $spec: dependencies resolved (wheels)"
    return 0
  fi
  echo "[info] $spec: some dependencies need a source build, trying pip wheel"
  if "$PY" -m pip wheel --wheel-dir "$OUT" "${ABI3_ARGS[@]}" --find-links "$LOCAL" --find-links "$OUT" "$spec" >/tmp/resolve.log 2>&1; then
    return 0
  fi
  if grep -qiE 'maturin|cargo|rust' /tmp/resolve.log; then
    ensure_rust || { echo "[error] Rust installation failed"; tail -20 /tmp/resolve.log; return 1; }
    "$PY" -m pip wheel --wheel-dir "$OUT" "${ABI3_ARGS[@]}" --find-links "$LOCAL" --find-links "$OUT" "$spec" && return 0
  fi
  tail -30 /tmp/resolve.log; return 1
}

resolve_tool "tt-smi==$TT_SMI_V"
resolve_tool "tt-flash==$TT_FLASH_V"

TP_LU="$("$PY" - "$TT_TOPOLOGY_V" <<'PY'
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
echo "[info] tt-topology requires pyluwen: ${TP_LU:-0.8.5}"
resolve_tool "tt-topology==$TT_TOPOLOGY_V"

# 4) locally built wheels override the same-version PyPI wheel
cp -f "$LOCAL"/*.whl "$OUT"/ 2>/dev/null || true

echo "[info] total wheels: $(find "$OUT" -name '*.whl' | wc -l)"
ls "$OUT" | sed 's/^/    /'
