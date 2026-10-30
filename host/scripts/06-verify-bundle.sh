#!/usr/bin/env bash
# Stage 6: static self-check of both deliverable formats
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DEBARCH="$(arch_deb "$ARCH")"
NAME="${PKG_PREFIX}_${BUNDLE_VER}_${DEBARCH}"
DEB_NAME="$NAME.deb"
TAR_OUT="$DIST_DIR/$NAME.tar.zst"
DEB_OUT="$DIST_DIR/$DEB_NAME"
FAIL=0
ok()  { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
info(){ printf '  [info] %s\n' "$*"; }

# ---------------------------------------------------------------- tar.zst
echo "== 1) tar.zst checks =="
[ -f "$TAR_OUT" ] || die "$TAR_OUT not found"
( cd "$DIST_DIR" && sha256sum -c "$NAME.tar.zst.sha256" >/dev/null ) && ok "sha256 matches" || bad "sha256 mismatch"
V="$WORK_DIR/verify/$NAME"
rm -rf "$V"; mkdir -p "$WORK_DIR/verify"
tar -C "$WORK_DIR/verify" -xf "$TAR_OUT"
[ -d "$V" ] && ok "extracted: $(du -sh "$V" | cut -f1)" || bad "extraction failed"

echo "== 2) required files in the bundle =="
for f in install.sh verify.sh uninstall.sh hugepages-setup.sh VERSION target-matrix.yaml manifest.yaml; do
  [ -f "$V/$f" ] && ok "$f" || bad "missing $f"
done
[ -n "$(find "$V/kmd" -name 'tenstorrent-*.tar.gz' -print -quit)" ] && ok "kmd source tarball" || bad "missing the kmd source tarball"
if [ -d "$V/kmd/prebuilt" ]; then ok "prebuilt modules: $(ls "$V/kmd/prebuilt" | tr '\n' ' ')"; else info "no prebuilt module (DKMS only)"; fi
[ -f "$V/systemd/tt-hugepages.service" ] && ok "systemd units" || bad "missing tt-hugepages.service"
[ -f "$V/udev/99-tenstorrent.rules" ] && ok "udev rules" || bad "udev rules missing"

echo "== 3) script syntax =="
for s in "$V"/*.sh; do
  if bash -n "$s"; then ok "$(basename "$s")"; else bad "$(basename "$s") syntax error"; fi
done

echo "== 4) wheelhouse completeness =="
for t in $TARGETS; do
  tag=$(pyver_tag "$(ubuntu_pyver "$t")")
  n=$(find "$V/wheelhouse/$tag" -name '*.whl' 2>/dev/null | wc -l)
  if [ "$n" -ge 10 ]; then ok "$t ($tag): $n wheel(s)"; else bad "$t ($tag): only $n wheel(s)"; fi
  for must in tt_smi tt_flash tt_topology pyluwen tt_umd; do
    find "$V/wheelhouse/$tag" -name "${must}-*.whl" | grep -q . || bad "$t ($tag) missing $must wheel"
  done
done

echo "== 5) install script dry-run =="
if bash "$V/install.sh" --check >"$LOG_DIR/install-check.log" 2>&1; then
  ok "install.sh --check passed"
elif grep -q 'Pre-flight checks' "$LOG_DIR/install-check.log"; then
  info "install.sh --check reported WARN/FAIL (build host environment, see $LOG_DIR/install-check.log)"
else
  bad "install.sh --check could not run"
fi

# ---------------------------------------------------------------- .deb
echo "== 6) .deb checks =="
if [ ! -f "$DEB_OUT" ]; then
  bad "$DEB_NAME not found"
else
  ( cd "$DIST_DIR" && sha256sum -c "$DEB_NAME.sha256" >/dev/null ) && ok "sha256 matches" || bad ".deb sha256 mismatch"
  ctl="$(dpkg-deb -f "$DEB_OUT" Package Version Architecture Depends Conflicts 2>/dev/null || true)"
  echo "$ctl" | sed 's/^/      /'
  echo "$ctl" | grep -q "^Package: tt-deps$" && ok "Package field" || bad "unexpected Package field"
  echo "$ctl" | grep -q "^Version: $BUNDLE_VER$" && ok "Version field" || bad "unexpected Version field"
  echo "$ctl" | grep -q "^Architecture: $DEBARCH$" && ok "Architecture=$DEBARCH" || bad "Architecture should be $DEBARCH"
  local_extra=""
  [ "$ARCH" = riscv64 ] && local_extra=" libtiff6 libjpeg-turbo8 liblcms2-2 libwebp7"
  for dep in dkms python3-venv zstd systemd$local_extra; do
    echo "$ctl" | grep -qi "$dep" && ok "Depends contains $dep" || bad "Depends is missing $dep"
  done
  echo "$ctl" | grep -qi 'tt-smi' && ok "Conflicts contains tt-smi" || bad "Conflicts is missing tt-smi"
  cnt="$(dpkg-deb -c "$DEB_OUT" 2>/dev/null | grep -cE 'opt/tt-deps/(install|verify|uninstall|hugepages-setup)\.sh')"
  [ "$cnt" -eq 4 ] && ok "all four payload scripts present" || bad "payload scripts incomplete ($cnt/4)"
  for s in postinst prerm postrm; do
    if dpkg-deb -e "$DEB_OUT" "$WORK_DIR/verify/deb-ctl" 2>/dev/null && [ -f "$WORK_DIR/verify/deb-ctl/$s" ]; then
      ok "maintainer script: $s"
    else
      bad "missing $s"
    fi
  done
  info "deb size: $(du -h "$DEB_OUT" | cut -f1)"
fi

echo
echo "== summary: FAIL=$FAIL =="
if [ "$FAIL" = 0 ]; then
  echo "BUNDLE_VERIFY_OK"
  log "artifacts:"
  log "  $TAR_OUT"
  log "  $DEB_OUT"
else
  echo "BUNDLE_VERIFY_FAILED"; exit 1
fi
