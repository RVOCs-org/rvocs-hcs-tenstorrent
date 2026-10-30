#!/usr/bin/env bash
# Stage 2: apply patches only.
#   Order: patches/common/<component>/series, then patches/<arch>/<component>/series
#   The work tree is reset on every run; --no-patch skips patching, --revert only reverts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[ -d "$SRC_DIR" ] || die "missing $SRC_DIR (run --stage fetch first)"
MARK="$WORK_DIR/patched-components.txt"
COMPONENTS="tt-kmd tt-umd tt-smi tt-flash tt-topology pyluwen"

reset_worktree() { # <component>
  local n="$1"
  if [ -d "$SRC_DIR/$n/.git" ]; then
    git -C "$SRC_DIR/$n" checkout --quiet -- . 2>/dev/null || true
    git -C "$SRC_DIR/$n" clean -qfd 2>/dev/null || true
    return 0
  fi
  # PyPI sdist component: re-extract the pristine tarball (there is no git to reset from)
  local ver tgz
  ver="$(sed -n 's/^pypi://p' "$WORK_DIR/src-refs/$n" 2>/dev/null)"
  tgz="$WORK_DIR/src-pristine/$n-$ver.tar.gz"
  [ -f "$tgz" ] || return 0
  rm -rf "$SRC_DIR/$n"; mkdir -p "$SRC_DIR/$n"
  tar xzf "$tgz" -C "$SRC_DIR/$n" --strip-components=1
}

if [ "${SKIP_PATCH:-0}" = 1 ]; then
  log "--no-patch: skipping patches, restoring the pristine sources"
  for n in $COMPONENTS; do reset_worktree "$n"; done
  : > "$MARK"
  log "patch stage finished (nothing applied)"
  exit 0
fi

if [ "${REVERT:-0}" = 1 ]; then
  log "reverting patches (git checkout of the work tree)"
  for n in $COMPONENTS; do
    reset_worktree "$n"
    log "  [$n] back to $(git -C "$SRC_DIR/$n" describe --tags 2>/dev/null || echo HEAD)"
  done
  : > "$MARK"
  log "revert finished"
  exit 0
fi

clean_line() { sed -e 's/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//'; }

: > "$MARK"

patch_component() { # <name>
  local name="$1"
  local dst="$SRC_DIR/$name"
  local total=0 applied=0 raw line p d rel
  [ -d "$dst" ] || die "[$name] source tree missing (run --stage fetch first)"
  reset_worktree "$name"

  local dirs
  dirs="$(patch_dirs_for "$name")" || dirs=""
  if [ -z "$dirs" ]; then
    log "  [$name] no patch directory, skipping"
    return 0
  fi

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rel="${d#$PATCH_DIR/}"
    if ! patch_dirs_has_entries "$d"; then
      log "    [$name] $rel: empty series"
      continue
    fi
    while IFS= read -r raw || [ -n "$raw" ]; do
      line="$(printf '%s' "$raw" | clean_line)"
      case "$line" in ''|'#'*) continue ;; esac
      total=$((total+1))
      p="$d/$line"
      [ -f "$p" ] || die "[$name] patch file not found: $rel/$line"
      if [ -d "$dst/.git" ]; then
        check_cmd=(git -C "$dst" apply --check "$p")
        apply_cmd=(git -C "$dst" apply "$p")
      else
        check_cmd=(patch -p1 -d "$dst" --dry-run --forward -i "$p")
        apply_cmd=(patch -p1 -d "$dst" --forward -i "$p")
      fi
      if ! "${check_cmd[@]}" 2>/dev/null; then
        die "[$name] patch does not apply cleanly: $rel/$line
  current source: $(cat "$WORK_DIR/src-refs/$name" 2>/dev/null || echo '?') / $(git -C "$dst" describe --tags 2>/dev/null || echo 'no tag')
  debug: cd $dst && git apply --check $p   (rebase the patch onto this version, or use --no-patch)"
      fi
      "${apply_cmd[@]}" >/dev/null 2>&1 || { echo "[error] $name: failed to apply $line" >&2; exit 1; }
      log "    [$name] ✓ $rel/$line"
      applied=$((applied+1))
    done < "$d/series"
  done <<< "$dirs"

  if [ "$applied" -gt 0 ]; then
    echo "$name" >> "$MARK"
    log "  [$name] applied $applied/$total patch(es)"
  else
    log "  [$name] no patches"
  fi
}

log "applying patches ($PATCH_DIR/common + $PATCH_DIR/$ARCH)"
for n in $COMPONENTS; do
  patch_component "$n"
done

if [ -s "$MARK" ]; then
  log "patched components: $(tr '\n' ' ' < "$MARK")"
else
  log "no patches in this run"
fi
log "patch stage finished"
