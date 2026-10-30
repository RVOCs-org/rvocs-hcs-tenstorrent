#!/bin/bash
# Tenstorrent 1G hugepage configuration (NUMA aware)
#
# Algorithm ported from /opt/es/bin/hugepages-setup.sh:
#   - Blackhole / Wormhole: 4 x 1G pages per card; Grayskull: 1 x 1G page per card
#   - an override file may set the total page count: /etc/tenstorrent/hugepages-override.txt
#     (the legacy path /opt/es/bin/hugepages-override.txt is honoured too), split evenly over the cards
# Differences from the old script: --show/--dry-run, safe exit without cards, run by systemd at boot (persistent).
#
# Usage: hugepages-setup.sh [--apply|--show|--dry-run]
#   --apply   write nr_hugepages (default; used by the systemd service)
#   --show    print the current and expected values only
#   --dry-run compute and print, do not write
set -eo pipefail

MODE="apply"
case "${1:---apply}" in
  --apply)   MODE="apply" ;;
  --show)    MODE="show" ;;
  --dry-run) MODE="dry-run" ;;
  -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

TT_VID=1e52
GS_PID=faca
WH_PID=401e
BH_PID=b140
HP_DIR_NAME="hugepages-1048576kB"

get_node_pages() { # <VIDPID> <multiplier> -> "<node> <pages>" per card
  lspci -d "$1" -vmm 2>/dev/null | awk "BEGIN {n=0} /NUMANode:/ {n=\$2} /^\$/ {print n \" $2\"}"
}

declare -A nodes
mapfile -t OVERRIDE_FILES < <(printf '%s\n' /etc/tenstorrent/hugepages-override.txt /opt/es/bin/hugepages-override.txt)
OVERRIDE=""
for f in "${OVERRIDE_FILES[@]}"; do
  if [ -f "$f" ]; then OVERRIDE="$(tr -d '[:space:]' < "$f")"; OVERRIDE_SRC="$f"; break; fi
done

if [ -n "$OVERRIDE" ]; then
  TT_COUNT=$(lspci -d "${TT_VID}:" 2>/dev/null | wc -l)
  [ "$TT_COUNT" -gt 0 ] || { echo "no Tenstorrent device detected; cannot split the override $OVERRIDE, exiting"; exit 0; }
  HP_COUNT=$((OVERRIDE / TT_COUNT))
  echo "override: $OVERRIDE pages (from $OVERRIDE_SRC), $HP_COUNT pages per card"
  while read -r idx val; do nodes[$idx]=$(( ${nodes[$idx]:-0} + val )); done < <(
    get_node_pages "${TT_VID}:${BH_PID}" "$HP_COUNT"
    get_node_pages "${TT_VID}:${WH_PID}" "$HP_COUNT"
    get_node_pages "${TT_VID}:${GS_PID}" "$HP_COUNT"
  )
else
  while read -r idx val; do nodes[$idx]=$(( ${nodes[$idx]:-0} + val )); done < <(
    get_node_pages "${TT_VID}:${BH_PID}" 4
    get_node_pages "${TT_VID}:${WH_PID}" 4
    get_node_pages "${TT_VID}:${GS_PID}" 1
  )
fi

if [ ${#nodes[@]} -eq 0 ]; then
  echo "no Tenstorrent device (VID ${TT_VID}); nothing to configure"
  exit 0
fi

rc=0
for n in $(printf '%s\n' "${!nodes[@]}" | sort -n); do
  HP_DIR="/sys/devices/system/node/node${n}/hugepages/${HP_DIR_NAME}"
  if [ ! -d "$HP_DIR" ]; then
    echo "[ERROR] cannot find $HP_DIR (1G hugepages disabled in the kernel?)" >&2; rc=1; continue
  fi
  cur=$(cat "$HP_DIR/nr_hugepages")
  want=${nodes[$n]}
  echo "node${n}: current=${cur} want=${want}"
  case "$MODE" in
    show) ;;
    dry-run) echo "  (dry-run) not writing" ;;
    apply)
      echo "$want" > "$HP_DIR/nr_hugepages" || { echo "[ERROR] write failed: $HP_DIR" >&2; rc=1; continue; }
      got=$(cat "$HP_DIR/nr_hugepages")
      if [ "$got" != "$want" ]; then
        echo "[WARN] expected $want, got $got (out of memory or pages in use)" >&2
      else
        echo "  -> set to $got"
      fi
      ;;
  esac
done

# Make sure hugetlbfs is mounted (systemd mounts it at boot; this is only a fallback)
if [ "$MODE" = "apply" ] && [ -d /dev ] && ! mountpoint -q /dev/hugepages-1G 2>/dev/null; then
  mkdir -p /dev/hugepages-1G
  mount -t hugetlbfs -o mode=777,pagesize=1024M none /dev/hugepages-1G 2>/dev/null \
    || echo "[WARN] failed to mount /dev/hugepages-1G (no card or permission problem)" >&2
fi

[ "$rc" = 0 ] && echo "hugepages configuration finished (mode=$MODE)"
exit $rc
