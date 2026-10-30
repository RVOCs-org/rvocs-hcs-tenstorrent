#!/usr/bin/env bash
# Post-install self-check: driver / devices / hugepages / tools (bare commands) / Python bindings
# On a machine without cards the device checks are WARN and do not count as failures
set -uo pipefail
ARCH="$(uname -m)"; KV="$(uname -r)"; DISTRO="$(. /etc/os-release; echo "${VERSION_ID:-?}")"
PYTAG="$(python3 -c 'import sys;print("py%d%d"%sys.version_info[:2])' 2>/dev/null || echo none)"
FAIL=0; WARN=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARN=$((WARN+1)); }

echo "== System =="
ok "arch=$ARCH distro=$DISTRO kernel=$KV python=$PYTAG"

echo "== Kernel driver =="
if lsmod | grep -q '^tenstorrent'; then ok "module tenstorrent is loaded"; else bad "module tenstorrent is not loaded (dmesg | grep -i tenstorrent)"; fi
if modinfo tenstorrent >/dev/null 2>&1; then ok "module file: $(modinfo -F filename tenstorrent | head -1)"; else warn "tenstorrent.ko not found"; fi
v="$(modinfo -F version tenstorrent 2>/dev/null | head -1)"; [ -n "$v" ] && ok "driver version $v"
[ -f /etc/modules-load.d/tenstorrent.conf ] && ok "automatic load at boot configured" || warn "missing /etc/modules-load.d/tenstorrent.conf"

echo "== Devices =="
cards=$(lspci -d 1e52: 2>/dev/null | wc -l)
[ "$cards" -gt 0 ] && ok "$cards Tenstorrent device(s) detected" || warn "no Tenstorrent device detected (expected without cards)"
if [ -d /dev/tenstorrent ] && [ -n "$(ls -A /dev/tenstorrent 2>/dev/null)" ]; then
  ok "device nodes: $(ls /dev/tenstorrent | tr '\n' ' ')"
else warn "/dev/tenstorrent is empty"; fi

echo "== Hugepages(1G)=="
tot=0
for d in /sys/devices/system/node/node*/hugepages/hugepages-1048576kB; do
  [ -d "$d" ] || continue
  n=$(cat "$d/nr_hugepages" 2>/dev/null || echo 0); node=$(echo "$d" | sed 's|.*/node\([0-9]*\)/.*|\1|')
  echo "  [info] node$node: $n pages x 1G"; tot=$((tot+n))
done
[ "$tot" -gt 0 ] && ok "1G hugepages total: $tot" || warn "1G hugepages is 0 (expected without cards)"
mountpoint -q /dev/hugepages-1G 2>/dev/null && ok "/dev/hugepages-1G is mounted" || bad "/dev/hugepages-1G is not mounted"
systemctl is-enabled tt-hugepages.service >/dev/null 2>&1 && ok "tt-hugepages.service is enabled (persistent)" || warn "tt-hugepages.service is not enabled"

echo "== Tools (bare commands, no venv / no sudo) =="
for t in tt-smi tt-flash tt-topology; do
  p="/usr/local/bin/$t"
  if [ -x "$p" ]; then
    if out="$("$p" --version 2>&1)"; then ok "$t -> $p  ($(echo "$out" | head -1))"
    else warn "$t exists but failed to run (common without a card): $(echo "$out" | head -1)"; fi
    [ -d "/opt/tenstorrent/tools/$t" ] && echo "  [info] isolated environment: /opt/tenstorrent/tools/$t"
  else bad "$t missing"; fi
done

echo "== Python bindings (inside each tool environment)=="
for t in tt-smi tt-flash tt-topology; do
  py="/opt/tenstorrent/tools/$t/bin/python"
  [ -x "$py" ] || continue
  for m in pyluwen tt_umd; do
    if "$py" -c "import $m" 2>/dev/null; then
      v="$("$py" -c "import $m;print(getattr($m,'__version__','?'))" 2>/dev/null)"
      ok "$t: import $m ($v)"
    fi
  done
done

echo
echo "== summary: FAIL=$FAIL WARN=$WARN =="
[ "$FAIL" = 0 ] && echo "VERIFY_OK" || { echo "VERIFY_FAILED"; exit 1; }
