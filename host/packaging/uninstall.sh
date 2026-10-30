#!/usr/bin/env bash
# Remove what tt-dependency-installer installed (Docker images are untouched)
# Usage: sudo ./uninstall.sh [--keep-kmd] [--purge]
set -euo pipefail
KEEP_KMD=0; PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-kmd) KEEP_KMD=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "root is required" >&2; exit 1; }
log() { printf '[uninstall] %s\n' "$*"; }

log "stopping the hugepage units"
systemctl disable --now tt-hugepages.service 2>/dev/null || true
systemctl disable --now "dev-hugepages\\x2d1G.mount" 2>/dev/null || true
rm -f /etc/systemd/system/tt-hugepages.service "/etc/systemd/system/dev-hugepages\\x2d1G.mount"
systemctl daemon-reload 2>/dev/null || true

log "removing the tools (per-tool environment plus the bare command)"
for t in tt-smi tt-flash tt-topology; do
  rm -f "/usr/local/bin/$t"
  rm -rf "/opt/tenstorrent/tools/$t"
done
python3 -m pip uninstall -y tt-smi tt-flash tt-topology >/dev/null 2>&1 || true

if [ "$KEEP_KMD" = 0 ]; then
  log "removing tt-kmd"
  KV="$(uname -r)"
  rm -f "/lib/modules/$KV/updates/tenstorrent.ko"
  depmod -a "$KV" 2>/dev/null || true
  modprobe -r tenstorrent 2>/dev/null || true
  for d in /usr/src/tenstorrent-*; do
    [ -d "$d" ] || continue
    ver="${d##*/tenstorrent-}"
    dkms remove -m tenstorrent -v "$ver" --all >/dev/null 2>&1 || true
    rm -rf "$d"
  done
  rm -f /etc/modules-load.d/tenstorrent.conf
fi

log "removing the udev rules"
rm -f /etc/udev/rules.d/99-tenstorrent.rules
udevadm control --reload-rules 2>/dev/null || true
rm -rf /opt/tenstorrent
[ "$PURGE" = 1 ] && rm -rf /etc/tenstorrent
log "done (hugepage values stay in the kernel but are no longer configured at boot)"
