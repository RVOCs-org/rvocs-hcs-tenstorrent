#!/usr/bin/env bash
# User-side bare-metal install (BETA / experimental)
#
# Goal: install the driver and tools on a bare "server + Tenstorrent card" OS and deploy the inference engine.
# Covers: system dependencies -> tt-kmd kernel module -> 1G hugepages -> Docker -> image -> launch command.
#
# IMPORTANT (read before use):
#   1. tt-kmd and firmware flashing are not yet tested on riscv64 hosts; x86_64 follows the official guide.
#   2. Root (sudo) is required; kernel modules and hugepage settings are modified.
#   3. Every step asks for confirmation and Ctrl-C aborts safely; --step jumps to a specific step.
#
# Usage:
#   sudo ./scripts/install-host.sh [--proxy cn|direct|auto] [--step deps|kmd|hugepages|docker|deploy]
#                                  [--image TAG] [--model Qwen3-8B] [--device n300]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

STEP=all
MODEL="${MODEL:-Qwen3-8B}"
DEVICE="${DEVICE:-n300}"
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY_MODE="$2"; shift 2 ;;
    --step)  STEP="$2"; shift 2 ;;
    --image) IMAGE_TAG="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
resolve_proxy

confirm() { read -r -p ">>> $1 [y/N] " ans; [ "${ans:-n}" = y ] || { echo "skipped"; return 1; }; }
want() { [ "$STEP" = all ] || [ "$STEP" = "$1" ]; }

# ---------------------------------------------------------------- 1. system dependencies
if want deps; then
  log "[deps] installing system dependencies ..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential dkms linux-headers-"$(uname -r)" git curl ca-certificates \
    debootstrap docker.io docker-buildx jq
  true
fi

# ---------------------------------------------------------------- 2. tt-kmd kernel module
if want kmd; then
  log "[kmd] building and loading tt-kmd (not yet tested on riscv64; see the official tt-kmd repo on failure) ..."
  confirm "continue building and installing tt-kmd?" || true
  KMD_DIR=/opt/tt-kmd
  if [ ! -d "$KMD_DIR" ]; then
    if [ "$PROXY" = 1 ]; then
      git -c "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" \
        clone https://github.com/tenstorrent/tt-kmd.git "$KMD_DIR"
    else
      git clone https://github.com/tenstorrent/tt-kmd.git "$KMD_DIR"
    fi
  fi
  make -C "$KMD_DIR" || die "tt-kmd build failed (riscv64 kernel support may need extra work)"
  make -C "$KMD_DIR" install
  modprobe tenstorrent || die "modprobe tenstorrent failed"
  ls -la /dev/tenstorrent/ || die "/dev/tenstorrent device nodes did not appear"
  log "tt-kmd ready"
fi

# ---------------------------------------------------------------- 3. 1G hugepages
if want hugepages; then
  log "[hugepages] configuring 1G hugepages (4 by default, adjust to the model size) ..."
  echo 4 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages || \
    die "hugepage reservation failed (check available memory)"
  mkdir -p /dev/hugepages-1G
  mountpoint -q /dev/hugepages-1G || mount -t hugetlbfs -o pagesize=1G none /dev/hugepages-1G
  grep Huge /proc/meminfo
fi

# ---------------------------------------------------------------- 4. Docker
if want docker; then
  log "[docker] starting Docker and loading the image ..."
  systemctl enable --now docker || true
  docker info >/dev/null 2>&1 || die "docker is not available"
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || docker pull "$IMAGE_TAG" \
    || warn "image pull failed: run docker load -i <tar from the release> manually and retry --step deploy"
fi

# ---------------------------------------------------------------- 5. deploy
if want deploy; then
  log "[deploy] inference service launch command (copy and run):"
  cat <<EOF

docker run -d --name tt-vllm \\
  --ipc host --publish 8000:8000 \\
  --device /dev/tenstorrent \\
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \\
  --volume volume_id_${MODEL}:/home/container_app_user/cache_root \\
  ${IMAGE_TAG} \\
  --model ${MODEL} --tt-device ${DEVICE}

# health check (initialization takes a few minutes):
#   curl -s http://127.0.0.1:8000/v1/models | jq .
#   curl -s http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \\
#     -d '{"model":"${MODEL}","messages":[{"role":"user","content":"hello"}]}'

EOF
fi

log "install-host finished (step=$STEP)"
