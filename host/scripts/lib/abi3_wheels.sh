#!/usr/bin/env bash
# Build pyo3/abi3 wheels (pyluwen) inside the dedicated abi3 build image
#
# Why a dedicated image:
#   - Ubuntu 26.04's rustc reports host=riscv64a23-unknown-linux-gnu, which target-lexicon cannot parse
#   - Ubuntu 24.04 has a standard triple but cargo 1.75 is too old (maturin needs edition2024, Rust >= 1.85)
#   - Debian 13 (trixie):rustc/cargo 1.85.1 + host=riscv64gc-unknown-linux-gnu + glibc 2.41
# Prefer the patched sources under /src; fall back to the PyPI sdist when no matching source exists.
#
# Environment: OUT, PYLUWEN_SPECS, CRATES_MIRROR, PIP_INDEX_URL, DEBIAN_MIRROR, CACHE,
#              SRC (mount point, default /src), PROTOC
set -euo pipefail
OUT="${OUT:?}"; mkdir -p "$OUT"
CACHE="${CACHE:-}"; SRC="${SRC:-/src}"
export DEBIAN_FRONTEND=noninteractive
export PROTOC="${PROTOC:-/usr/bin/protoc}"

# Debian mirrors are slow from CN and debian:13 ships no ca-certificates, so https fails; use http
if [ -n "${DEBIAN_MIRROR:-}" ]; then
  echo "[abi3] Debian mirror -> $DEBIAN_MIRROR"
  for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    sed -i "s|https\?://deb.debian.org/debian|${DEBIAN_MIRROR}|g; s|https\?://security.debian.org/debian-security|${DEBIAN_MIRROR}-security|g" "$f"
  done
fi

echo "[abi3] installing the toolchain ..."
apt-get update -qq
# protobuf-compiler is required: luwen-api/build.rs uses a vendored protoc, which only ships for
# x86_64/aarch64, so riscv64 fails with `Error { os: "linux", arch: "riscv64" }`.
# Our patch makes it honour the PROTOC environment variable (pointing at the system protoc).
apt-get install -y -qq ca-certificates python3 python3-pip python3-dev python3-venv build-essential \
      rustc cargo curl pkg-config protobuf-compiler git >/dev/null
echo "[abi3] protoc: $(protoc --version 2>/dev/null || echo MISSING)  PROTOC=$PROTOC"

echo "[abi3] python=$(python3 -V 2>&1 | cut -d' ' -f2) rustc=$(rustc --version | cut -d' ' -f2) host=$(rustc -vV | sed -n 's/^host: //p') cargo=$(cargo --version | cut -d' ' -f2)"

if [ -n "${CRATES_MIRROR:-}" ]; then
  mkdir -p "$HOME/.cargo"
  cat > "$HOME/.cargo/config.toml" <<EOF
[source.crates-io]
replace-with = "mirror"

[source.mirror]
registry = "sparse+${CRATES_MIRROR}"
EOF
  echo "[abi3] crates mirror: sparse+${CRATES_MIRROR}"
else
  echo "[abi3] crates index: official index.crates.io"
fi

# pyluwen's Cargo manifest does not enable abi3 (a plain build yields cp313-cp313, unusable on 3.14).
# Upstream's PyPI abi3 wheels enable pyo3's abi3 feature, so do the same here.
export MATURIN_PEP517_ARGS="${MATURIN_PEP517_ARGS:---features pyo3/abi3-py311 --compatibility linux}"
echo "[abi3] MATURIN_PEP517_ARGS=$MATURIN_PEP517_ARGS"

NOISO=""
install_maturin() {
  if [ -n "$CACHE" ] && ls "$CACHE"/maturin-*.whl >/dev/null 2>&1; then
    python3 -m pip install -q --break-system-packages --no-index --find-links "$CACHE" maturin
    echo "[abi3] maturin (cached) $(maturin --version 2>/dev/null || echo '?')"
    return 0
  fi
  if [ -n "$CACHE" ] && python3 -m pip wheel -q --no-deps -w "$CACHE" maturin >/tmp/maturin-build.log 2>&1; then
    python3 -m pip install -q --break-system-packages --no-index --find-links "$CACHE" maturin
    echo "[abi3] maturin (created and cached) $(maturin --version 2>/dev/null || echo '?')"
    return 0
  fi
  if python3 -m pip install -q --break-system-packages maturin >/tmp/maturin.log 2>&1; then
    echo "[abi3] maturin(pip) $(maturin --version 2>/dev/null || echo '?')"
    return 0
  fi
  return 1
}
if install_maturin; then
  NOISO="--no-build-isolation"
elif apt-get install -y -qq maturin >/dev/null 2>&1; then
  echo "[abi3] maturin(apt) $(maturin --version 2>/dev/null || echo '?')"
  NOISO="--no-build-isolation"
else
  echo "[abi3] maturin unavailable, letting pip build isolation handle it (may be slow)"
fi

# Pick the source dir: /src/pyluwen-<ver> first, then /src/pyluwen (main ref); the version must match
pick_source() { # <version>
  local ver="$1" d
  for d in "$SRC/pyluwen-$ver" "$SRC/pyluwen"; do
    [ -f "$d/Cargo.toml" ] || continue
    if grep -qE "^version *= *\"$ver\"" "$d/Cargo.toml" 2>/dev/null \
       || grep -qE "^version *= *\"$ver\"" "$d"/crates/luwen-api/Cargo.toml 2>/dev/null; then
      echo "$d"; return 0
    fi
  done
  return 1
}

rc=0
for spec in ${PYLUWEN_SPECS:-}; do
  ver="${spec##*==}"
  target=""
  work=""
  if src="$(pick_source "$ver")"; then
    # sources are read-only but cargo writes Cargo.lock, so copy to a writable temp dir
    work="$(mktemp -d)"
    tar -C "$src" -cf - --exclude=.git . 2>/dev/null | tar -C "$work" -xf - 2>/dev/null
    target="$work"
    echo "[abi3] building $spec (source: $src, writable copy) ..."
  else
    target="$spec"
    echo "[abi3] building $spec (no matching source, falling back to the PyPI sdist) ..."
  fi
  log="/tmp/abi3-$(echo "$spec" | tr -c 'a-zA-Z0-9' '_').log"
  # shellcheck disable=SC2086
  if python3 -m pip wheel --no-deps --wheel-dir "$OUT" $NOISO "$target" >"$log" 2>&1; then
    echo "[abi3] OK: $spec"
  else
    echo "[abi3] FAIL: $spec"; tail -25 "$log"; rc=1
  fi
  [ -n "$work" ] && rm -rf "$work"
done

echo "[abi3] artifacts:"
ls -la "$OUT" | sed 's/^/  /'
[ "$rc" = 0 ] || exit 1
