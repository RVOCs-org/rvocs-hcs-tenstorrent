#!/usr/bin/env bash
# tt-dependency-installer target host installer
#
# Installs the tt-kmd driver (DKMS or prebuilt), tt-smi/tt-flash/tt-topology as directly
#           one isolated environment per tool, no venv activation and no sudo needed), persistent 1G hugepages, udev rules
#
# Usage: sudo ./install.sh [--check] [--skip-kmd] [--skip-tools] [--skip-hugepages] [--yes]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "$HERE/VERSION" 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
KV="$(uname -r)"
DISTRO="$(. /etc/os-release; echo "${VERSION_ID:-unknown}")"
TT_ROOT=/opt/tenstorrent
CHECK=0; SKIP_KMD=0; SKIP_TOOLS=0; SKIP_HP=0; ASSUME_YES=0
APT_DISABLED="${APT_DISABLED:-0}"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --skip-kmd) SKIP_KMD=1; shift ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    --skip-hugepages) SKIP_HP=1; shift ;;
    --no-apt) APT_DISABLED=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

PYTAG="$(python3 -c 'import sys;print("py%d%d"%sys.version_info[:2])' 2>/dev/null || echo none)"
WH="$HERE/wheelhouse/$PYTAG"
SUPPORTED_DISTROS="$(sed -n 's/^distros: *//p' "$HERE/target-matrix.yaml" 2>/dev/null)"

log "tt-deps $VERSION  arch=$ARCH kernel=$KV distro=$DISTRO python=$PYTAG"

# ---------------------------------------------------------------- Pre-flight checks
precheck() {
  local fail=0; echo "--- Pre-flight checks ---"
  case "$ARCH" in riscv64|x86_64) echo "  [OK]   architecture $ARCH" ;;
    *) echo "  [FAIL] unsupported architecture $ARCH"; fail=$((fail+1)) ;; esac
  if [ -n "$SUPPORTED_DISTROS" ] && ! echo " $SUPPORTED_DISTROS " | grep -q " $DISTRO "; then
    echo "  [WARN] distribution $DISTRO is not in the supported list ($SUPPORTED_DISTROS)"
  else echo "  [OK]   distribution Ubuntu $DISTRO"; fi
  if [ -d "/lib/modules/$KV/build" ]; then echo "  [OK]   kernel headers"
  elif [ -f "$HERE/kmd/prebuilt/$KV/tenstorrent.ko.zst" ]; then echo "  [OK]   prebuilt module available"
  else echo "  [WARN] no kernel headers and no prebuilt module (needs linux-headers-$KV)"; fi
  if [ -d "$WH" ]; then echo "  [OK]   wheelhouse/$PYTAG: $(find "$WH" -name '*.whl' | wc -l) wheel(s)"
  else echo "  [FAIL] missing wheelhouse/$PYTAG"; fail=$((fail+1)); fi
  echo "  [info] installed tools: $(command -v tt-smi || echo none)"
  return $fail
}
precheck || { [ "$CHECK" = 1 ] && exit 1 || warn "pre-flight checks reported failures, continuing anyway"; }
[ "$CHECK" = 1 ] && { log "--check done (nothing changed)"; exit 0; }
[ "$(id -u)" = 0 ] || die "installation requires root: sudo $0"

# ---------------------------------------------------------------- dependencies
install_deps() {
  # Runtime libraries for the wheels we build from source: on riscv64 the
  # wheelhouse ships a source-built Pillow (no wheel upstream), whose extension
  # modules link libtiff/libjpeg/lcms2/libwebp at runtime.
  local required="dkms build-essential python3 python3-pip python3-venv zstd"
  case "$ARCH" in
    riscv64) required="$required libtiff6 libjpeg-turbo8 liblcms2-2 libwebp7" ;;
  esac
  local missing=() p
  for p in $required; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  # Kernel headers are only needed when there is no prebuilt module for this kernel
  local need_headers=0
  if [ ! -d "/lib/modules/$KV/build" ] && [ ! -f "$HERE/kmd/prebuilt/$KV/tenstorrent.ko.zst" ]; then
    need_headers=1
  fi

  if [ ${#missing[@]} -eq 0 ] && [ "$need_headers" = 0 ]; then
    log "system dependencies already satisfied"
    return 0
  fi

  # Never run apt from a dpkg maintainer script: the parent apt/dpkg owns
  # /var/lib/dpkg/lock-frontend, so a nested apt-get would wait on it forever
  # ("Waiting for cache lock ... held by process <parent apt>") and deadlock.
  if [ "${APT_DISABLED:-0}" = 1 ] || [ -n "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
    local hint=""
    [ ${#missing[@]} -gt 0 ] && hint="sudo apt-get install -y ${missing[*]}"
    [ "$need_headers" = 1 ] && hint="${hint:+$hint && }sudo apt-get install -y linux-headers-$KV"
    warn "missing packages: ${missing[*]:-none}${need_headers:+ }$( [ "$need_headers" = 1 ] && echo "(kernel headers for $KV)" )"
    warn "this runs inside a dpkg maintainer script, so apt is not invoked here."
    warn "install the packages above and re-run: sudo /opt/tt-deps/install.sh"
    die "cannot continue without: ${hint:-dependencies}"
  fi

  local pkgs=("${missing[@]}")
  [ "$need_headers" = 1 ] && pkgs+=("linux-headers-$KV")
  log "installing system dependencies: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" \
    || die "dependency installation failed"
}

# ---------------------------------------------------------------- tt-kmd
install_kmd() {
  log "installing tt-kmd ..."
  local pre="$HERE/kmd/prebuilt/$KV/tenstorrent.ko.zst"
  if [ -f "$pre" ]; then
    log "  using the prebuilt module ($KV)"
    mkdir -p "/lib/modules/$KV/updates"
    zstd -q -d -f "$pre" -o "/lib/modules/$KV/updates/tenstorrent.ko"
    depmod -a "$KV"
  else
    local src; src="$(ls "$HERE"/kmd/tenstorrent-*.tar.gz 2>/dev/null | head -1)"
    [ -n "$src" ] || { warn "no driver sources or module in the bundle, skipping"; return 0; }
    local ver; ver="$(basename "$src" .tar.gz)"; ver="${ver#tenstorrent-}"
    log "  DKMS install tenstorrent/$ver (first build takes 1-2 minutes)"
    mkdir -p /usr/src
    tar xzf "$src" -C /usr/src/
    dkms remove -m tenstorrent -v "$ver" --all >/dev/null 2>&1 || true
    dkms add -m tenstorrent -v "$ver" >/dev/null
    dkms build -m tenstorrent -v "$ver"
    dkms install -m tenstorrent -v "$ver" --force
  fi
  echo tenstorrent > /etc/modules-load.d/tenstorrent.conf
  modprobe tenstorrent 2>/dev/null || warn "modprobe failed (harmless without a card)"
  lsmod | grep -q '^tenstorrent' && log "  module loaded" || warn "module not loaded"
}

# ---------------------------------------------------------------- udev
install_udev() {
  [ -f "$HERE/udev/99-tenstorrent.rules" ] || return 0
  install -Dm644 "$HERE/udev/99-tenstorrent.rules" /etc/udev/rules.d/99-tenstorrent.rules
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=pci 2>/dev/null || true
  log "udev rules installed (/dev/tenstorrent/* mode 0666)"
}

# ---------------------------------------------------------------- tools (one environment per tool + bare command)
install_tools() {
  log "installing tools (one isolated environment per tool, commands usable directly)"
  mkdir -p "$TT_ROOT/tools"
  local tool spec
  for tool in tt-smi tt-flash tt-topology; do
    local venv="$TT_ROOT/tools/$tool"
    log "  [$tool] creating environment $venv"
    rm -rf "$venv"
    python3 -m venv "$venv" || die "$tool: venv creation failed (python3-venv missing?)"
    "$venv/bin/python" -m pip install -q --no-index --find-links "$WH" "$tool" \
      >/tmp/tt-pip-$tool.log 2>&1 || {
        tail -15 /tmp/tt-pip-$tool.log; die "$tool installation failed (see /tmp/tt-pip-$tool.log)"; }
    # bare-command wrapper (no venv, no sudo)
    cat > "/usr/local/bin/$tool" <<EOF
#!/bin/sh
exec "$venv/bin/$tool" "\$@"
EOF
    chmod 755 "/usr/local/bin/$tool"
    if "/usr/local/bin/$tool" --version >/dev/null 2>&1; then
      log "  [$tool] OK -> /usr/local/bin/$tool($("/usr/local/bin/$tool" --version 2>&1 | head -1))"
    else
      warn "  [$tool] installed but --version failed (common without a card; verify.sh re-checks)"
    fi
  done
}

# ---------------------------------------------------------------- hugepages (persistent)
install_hugepages() {
  log "configuring 1G hugepages (NUMA aware, persistent across reboot)"
  install -Dm755 "$HERE/hugepages-setup.sh" "$TT_ROOT/bin/hugepages-setup.sh"
  # the source file is called *-1G.mount.tpl so that the repository can be
  # checked out on Windows (a backslash in a file name is not portable);
  # the installed unit keeps the systemd-escaped name
  install -Dm644 "$HERE/systemd/dev-hugepages-1G.mount.tpl" "/etc/systemd/system/dev-hugepages\\x2d1G.mount"
  install -Dm644 "$HERE/systemd/tt-hugepages.service" /etc/systemd/system/tt-hugepages.service
  systemctl daemon-reload
  systemctl enable --now "dev-hugepages\\x2d1G.mount" 2>/dev/null || warn "failed to start the mount unit"
  systemctl enable tt-hugepages.service >/dev/null 2>&1 || true
  systemctl restart tt-hugepages.service || warn "hugepages service failed (expected without a card)"
  "$TT_ROOT/bin/hugepages-setup.sh" --show || true
}

[ "$SKIP_KMD" = 0 ] && { install_deps; install_kmd; }
install_udev
[ "$SKIP_TOOLS" = 0 ] && install_tools
[ "$SKIP_HP" = 0 ] && install_hugepages

mkdir -p /etc/tenstorrent
cat > /etc/tenstorrent/install-manifest.yaml <<EOF
bundle_version: "$VERSION"
installed_at: "$(date -Is)"
arch: $ARCH
distro: "$DISTRO"
kernel: "$KV"
python: "$PYTAG"
tools_layout: "per-tool venv under /opt/tenstorrent/tools, wrappers in /usr/local/bin"
EOF
log "install record: /etc/tenstorrent/install-manifest.yaml"

log "running self-check ..."
bash "$HERE/verify.sh" || warn "self-check reported failures (see above)"
