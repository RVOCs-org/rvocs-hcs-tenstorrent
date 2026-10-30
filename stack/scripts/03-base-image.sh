#!/usr/bin/env bash
# Stage 3 (riscv64 only): base image
#   There is no official riscv64 tt-metalium image, so it is built here. By default **no root and no debootstrap** are needed:
#     1) BASE_IMAGE already present locally          -> skip
#     2) BASE_PULL=1 (or BASE_IMAGE_REF set)        -> pull from a registry (GHCR distribution recommended)
#     3) build directly FROM ${BASE_OS_IMAGE}       -> official Ubuntu riscv64 image (ubuntu:26.04 by default)
#     4) USE_DEBOOTSTRAP=1                          -> debootstrap in a container to build the rootfs (still no host root)
#   On failure three manual fallbacks are printed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd docker

hint_manual() {
  warn "base image build failed. Manual fallbacks, easiest first:"
  cat >&2 <<EOF

  1) import from another machine (easiest, no root, no network):
       docker save $BASE_IMAGE | gzip > base.tgz        # source machine
       docker load -i base.tgz                          # this machine

  2) build it once by hand (needs sudo once; the script needs no root afterwards):
       sudo debootstrap --arch=$ARCH --variant=minbase $UBUNTU_CODENAME /var/tmp/rootfs-$ARCH $UBUNTU_MIRROR
       sudo tar -C /var/tmp/rootfs-$ARCH -c . | docker import - $ROOTFS_IMAGE
       sudo rm -rf /var/tmp/rootfs-$ARCH
       docker build -t $BASE_IMAGE -f "$REPO_ROOT/docker/base.Dockerfile" "$REPO_ROOT/docker"

  3) minimal passwordless sudo (unattended long term; docker itself needs no sudo):
       echo "ubuntu ALL=(ALL) NOPASSWD: /usr/sbin/debootstrap, /usr/bin/tar, /usr/bin/rm" | sudo tee /etc/sudoers.d/rvocs
       sudo chmod 440 /etc/sudoers.d/rvocs


EOF
}
trap hint_manual ERR

if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  log "base image already present: $BASE_IMAGE (docker rmi it to rebuild)"
  exit 0
fi

# 2) try the registry first (artifact distribution)
if [ "${BASE_PULL:-0}" = 1 ] || [ -n "${BASE_IMAGE_REF:-}" ]; then
  REF="${BASE_IMAGE_REF:-$BASE_IMAGE}"
  log "trying to pull the base image: $REF"
  if docker pull "$REF"; then
    if [ "$REF" != "$BASE_IMAGE" ]; then docker tag "$REF" "$BASE_IMAGE"; fi
    log "base image ready (from the registry): $BASE_IMAGE"
    trap - ERR
    exit 0
  fi
  warn "pull failed, building locally instead"
fi

BASE_SRC="$BASE_OS_IMAGE"

# 4) optional faithful path: debootstrap in a container (no host root)
if [ "${USE_DEBOOTSTRAP:-0}" = 1 ]; then
  ROOTFS="$WORK_DIR/rootfs-$ARCH"
  log "building the rootfs with debootstrap in a container (no host root): $UBUNTU_CODENAME @ $UBUNTU_MIRROR"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  docker run --rm -v "$ROOTFS:/target" -e DEBIAN_FRONTEND=noninteractive \
    -e CODENAME="$UBUNTU_CODENAME" -e MIRROR="$UBUNTU_MIRROR" "$BASE_OS_IMAGE" bash -c '
      apt-get update -qq && apt-get install -y -qq debootstrap ca-certificates >/dev/null
      debootstrap --variant=minbase "$CODENAME" /target "$MIRROR"'
  log "importing rootfs: $ROOTFS_IMAGE"
  tar -C "$ROOTFS" -c . | docker import - "$ROOTFS_IMAGE"
  rm -rf "$ROOTFS"
  BASE_SRC="$ROOTFS_IMAGE"
fi

# 3) build the toolchain layer directly
log "building the base image: $BASE_IMAGE (FROM $BASE_SRC)"
DOCKER_BUILDKIT=1 docker build --network host \
  --build-arg BASE_OS_IMAGE="$BASE_SRC" \
  -t "$BASE_IMAGE" \
  -f "$REPO_ROOT/docker/base.Dockerfile" \
  "$REPO_ROOT/docker"

trap - ERR
log "base image ready: $BASE_IMAGE"
