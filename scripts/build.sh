#!/usr/bin/env bash
# ============================================================================
# Tenstorrent vendor repository - thin entry point
#
# One repository per vendor, two parts:
#   host/   host-side dependencies (kernel driver, tools, hugepages, udev)
#   stack/  the device-stack image build (TT-Metal + vLLM)
#
# Each part keeps its own scripts, patches and manifest.yaml; this wrapper only
# forwards arguments:
#
#   ./scripts/build.sh --part host  [args...]   -> host/scripts/build.sh
#   ./scripts/build.sh --part stack [args...]   -> stack/scripts/build.sh
#   ./scripts/build.sh --part all   [args...]   -> host, then stack
#
# Everything after --part is passed through unchanged (see the part's own
# --help for arch/stage/proxy options).
# ============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PART=all
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --part) PART="${2:?--part requires host|stack|all}"; shift 2 ;;
    *)      args+=("$1"); shift ;;
  esac
done

run_part() {
  local part="$1"
  local entry="$REPO_ROOT/$part/scripts/build.sh"
  [ -f "$entry" ] || { echo "[ERROR] missing entry: $entry" >&2; exit 1; }
  echo
  echo "============================================================"
  echo " $part"
  echo "============================================================"
  bash "$entry" "${args[@]}"
}

case "$PART" in
  host)  run_part host ;;
  stack) run_part stack ;;
  all)   run_part host; run_part stack ;;
  *)     echo "[ERROR] unknown --part: $PART (expected host|stack|all)" >&2; exit 1 ;;
esac
