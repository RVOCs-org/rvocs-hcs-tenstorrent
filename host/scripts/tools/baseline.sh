#!/usr/bin/env bash
# ============================================================================
# Baseline switching driven by manifest.yaml (single input, one command)
#
# Edit the module's `ref:` in manifest.yaml - a tag, a branch or a commit sha -
# then run `apply`. The tool
#   1) resolves ref -> full 40-hex commit
#   2) moves the submodule gitlink (checkout --detach + git add), when the repo
#      uses submodules
#   3) writes commit: <full sha> back into manifest.yaml
#
#   ./scripts/tools/baseline.sh status            # ref / manifest commit / gitlink / HEAD
#   ./scripts/tools/baseline.sh apply [--dry-run] [--records] [--module <name>]
#     --records  only write the commit: lines (no submodule checkout/git add),
#                useful before the submodules are fetched
#   ./scripts/tools/baseline.sh check             # non-zero exit when anything is off
#
# The repository layout is detected automatically:
#   - manifest section `upstream:` + .gitmodules -> submodules under upstream/<name>
#   - manifest section `sources:`                -> fetched sources under work/src/<name>
#
# Scope: baseline only. Patches and builds are separate stages.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$REPO_ROOT/manifest.yaml"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }

[ -f "$MANIFEST" ] || die "missing manifest: $MANIFEST"

# git wrapper: GH_PROXY=1 routes github.com through gh-proxy (same idea as the
# sub-repos' --proxy cn, without touching the user's gitconfig)
git_c() {
  if [ "${GH_PROXY:-0}" = 1 ]; then
    git -c "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" "$@"
  else
    git "$@"
  fi
}

# ---------------------------------------------------------------- auto config
if grep -qE '^upstream:' "$MANIFEST"; then
  SECTION="upstream"
else
  SECTION="sources"
fi
if [ "$SECTION" = upstream ] && [ -f "$REPO_ROOT/.gitmodules" ]; then
  SUBMODULES=1
  PATH_PREFIX="upstream"
else
  SUBMODULES=0
  PATH_PREFIX="$([ "$SECTION" = sources ] && echo work/src || echo upstream)"
fi

# ---------------------------------------------------------------- manifest I/O
# one line per module: name <TAB> path <TAB> ref <TAB> commit <TAB> url
manifest_entries() {
  awk -v sec="$SECTION" -v pfx="$PATH_PREFIX" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      # flush the pending entry: the last module is followed by the next top-level key
      if (insub && name != "") printf "%s|%s|%s|%s|%s\n", name, (path==""?pfx"/"name:path), ref, commit, url
      insub = (index($0, sec":") == 1); name=""; next
    }
    insub && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (name != "") printf "%s|%s|%s|%s|%s\n", name, (path==""?pfx"/"name:path), ref, commit, url
      name=$1; sub(":","",name); path=""; ref=""; commit=""; url=""; next
    }
    insub && name!="" && /^    (submodule_path|path):/ { p=$0; sub(/^[[:space:]]*[a-z_]+:[[:space:]]*/,"",p); sub(/[[:space:]]*#.*/,"",p); path=p; next }
    insub && name!="" && /^    url:/    { u=$0; sub(/^[[:space:]]*url:[[:space:]]*/,"",u);    sub(/[[:space:]]*#.*/,"",u); url=u; next }
    insub && name!="" && /^    ref:/    { r=$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r);    sub(/[[:space:]]*#.*/,"",r); ref=r; next }
    insub && name!="" && /^    commit:/ { c=$0; sub(/^[[:space:]]*commit:[[:space:]]*/,"",c); sub(/[[:space:]]*#.*/,"",c); commit=c; next }
    END { if (name != "") printf "%s|%s|%s|%s|%s\n", name, (path==""?pfx"/"name:path), ref, commit, url }
  ' "$MANIFEST"
}

# write_commit <module> <full sha>: rewrite, or insert after ref, the commit line
write_commit() {
  local mod="$1" sha="$2" tmp
  [ "$DRY_RUN" = 1 ] && { printf '  [dry-run] manifest: %s.commit = %s\n' "$mod" "$sha"; return 0; }
  tmp="$(mktemp)"
  if awk -v sec="$SECTION" -v mod="$mod" -v sha="$sha" '
      /^[A-Za-z_][A-Za-z0-9_]*:/ { insub = (index($0, sec":") == 1) }
      insub && /^  / && !/^    / { name=$1; sub(":","",name) }
      insub && name==mod && /^    commit:/ { next }
      insub && name==mod && /^    ref:/    { print; printf "    commit: %s\n", sha; done=1; next }
      { print }
      END { exit (done ? 0 : 3) }
    ' "$MANIFEST" > "$tmp"; then
    mv "$tmp" "$MANIFEST"
  else
    rm -f "$tmp"
    die "module '$mod' has no 'ref:' line in section '$SECTION' of manifest.yaml"
  fi
}

# ---------------------------------------------------------------- helpers
sha_like() { case "$1" in ''|*[!0-9a-fA-F]*) return 1 ;; esac; [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]; }
is_full_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 40 ]; }

resolve_in_dir() { # <dir> <ref> -> full sha
  local dir="$1" ref="$2" c=""
  [ -e "$dir/.git" ] || [ -e "$dir" ] || return 1
  c=$(git -C "$dir" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  if [ -z "$c" ]; then
    git_c -C "$dir" fetch --tags --prune origin >/dev/null 2>&1 || true
    c=$(git -C "$dir" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  fi
  if [ -z "$c" ]; then
    c=$(git -C "$dir" rev-parse --verify --quiet "origin/${ref}^{commit}" 2>/dev/null || true)
  fi
  [ -n "$c" ] || return 1
  printf '%s' "$c"
}

resolve_remote() { # <url> <ref> -> full sha (works without a local checkout)
  local url="$1" ref="$2" out c=""
  [ -n "$url" ] || return 1
  out=$(git_c ls-remote "$url" "refs/tags/${ref}^{}" "refs/tags/${ref}" "refs/heads/${ref}" 2>/dev/null || true)
  # prefer the dereferenced annotated-tag entry
  c=$(printf '%s\n' "$out" | awk '/\^\{\}$/{print $1; exit}')
  [ -n "$c" ] || c=$(printf '%s\n' "$out" | awk 'NR==1{print $1}')
  [ -n "$c" ] || return 1
  printf '%s' "$c"
}

gitlink_of() { # <path> -> gitlink sha from the index (what the next commit records)
  git -C "$REPO_ROOT" ls-files -s -- "$1" 2>/dev/null | awk '$1=="160000"{print $2}'
}

head_gitlink_of() { # <path> -> gitlink sha recorded in HEAD
  git -C "$REPO_ROOT" ls-tree HEAD -- "$1" 2>/dev/null | awk '$2=="commit"{print $3}'
}

# ---------------------------------------------------------------- commands
cmd_status() {
  local name path ref commit url gl hgl head state
  printf '%-24s %-14s %-12s %-12s %-12s %s\n' MODULE REF MANIFEST GITLINK HEAD STATE
  while IFS='|' read -r name path ref commit url; do
    [ -n "$name" ] || continue
    gl=""; hgl=""; head=""
    if [ "$SUBMODULES" = 1 ]; then
      gl=$(gitlink_of "$path")
      hgl=$(head_gitlink_of "$path")
      [ -e "$path/.git" ] && head=$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)
    fi
    if [ -z "$commit" ]; then
      state="no-commit"
    elif ! is_full_sha "$commit"; then
      state="short-commit"
    elif [ "$SUBMODULES" = 1 ] && [ -n "$gl" ] && [ "${commit:0:12}" != "${gl:0:12}" ]; then
      state="drift"
    elif [ "$SUBMODULES" = 1 ] && [ -n "$hgl" ] && [ "$gl" != "$hgl" ]; then
      state="staged"
    elif [ "$SUBMODULES" = 1 ] && [ -n "$head" ] && [ "${commit:0:12}" != "${head:0:12}" ]; then
      state="worktree-differs"
    else
      state="ok"
    fi
    printf '%-24s %-14s %-12s %-12s %-12s %s\n' \
      "$name" "$ref" "${commit:0:12}" "${gl:0:12}" "${head:--}" "$state"
  done < <(manifest_entries)
  echo
  echo "state: ok = manifest, gitlink and work tree agree; drift = manifest vs gitlink;"
  echo "       worktree-differs = gitlink vs checked-out HEAD; short-commit/no-commit = run apply"
}

cmd_apply() {
  local only="${1:-}" name path ref commit url sha updated=0 skipped=0
  while IFS='|' read -r name path ref commit url; do
    [ -n "$name" ] || continue
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    [ -n "$ref" ] || { warn "$name: no ref in manifest, skipped"; skipped=$((skipped+1)); continue; }

    if [ "${RECORDS_ONLY:-0}" = 1 ] && [ "$SUBMODULES" = 1 ]; then
      # records mode: the gitlink stays as it is (authoritative) and only the
      # commit record is filled in; a ref pointing elsewhere is reported
      sha=$(gitlink_of "$path")
      [ -n "$sha" ] || die "$name: no gitlink for $path in the index"
      case "$sha" in
        "$ref"*) : ;;   # ref is already a (possibly abbreviated) sha of the pin
        *)
          if rsha=$(resolve_remote "$url" "$ref" 2>/dev/null); then
            [ "$rsha" = "$sha" ] || warn "$name: ref '$ref' resolves to ${rsha:0:12} but the gitlink is ${sha:0:12}; update ref if it should follow a tag"
          else
            warn "$name: ref '$ref' could not be resolved (offline?), commit record filled from the gitlink"
          fi
          ;;
      esac
    elif [ "$SUBMODULES" = 1 ]; then
      if [ ! -e "$path/.git" ]; then
        log "$name: initializing submodule $path"
        if [ "$DRY_RUN" = 1 ]; then
          printf '  [dry-run] git -C %s submodule update --init -- %s\n' "$REPO_ROOT" "$path"
        else
          git_c -C "$REPO_ROOT" submodule update --init -- "$path" >/dev/null 2>&1 \
            || die "$name: cannot initialize submodule $path"
        fi
      fi
      if sha=$(resolve_in_dir "$path" "$ref" 2>/dev/null); then :; else
        sha=$(resolve_remote "$url" "$ref") || die "$name: cannot resolve ref '$ref' (tag, branch or sha not found upstream)"
      fi
    else
      # sources repo: nothing to move, only record the resolved commit
      if is_full_sha "$ref"; then
        sha="$ref"
      elif sha=$(resolve_in_dir "$path" "$ref" 2>/dev/null); then :; else
        sha=$(resolve_remote "$url" "$ref") \
          || { warn "$name: cannot resolve '$ref' (offline?); skipped"; skipped=$((skipped+1)); continue; }
      fi
    fi

    log "$name: $ref -> ${sha:0:12}"
    if [ "$SUBMODULES" = 1 ] && [ "${RECORDS_ONLY:-0}" != 1 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] git -C %s checkout --detach %s\n' "$path" "$sha"
        printf '  [dry-run] git -C %s add %s\n' "$REPO_ROOT" "$path"
      else
        git -C "$path" checkout --detach "$sha" >/dev/null 2>&1 || die "$name: checkout failed in $path"
        git -C "$REPO_ROOT" add "$path"
      fi
    fi
    write_commit "$name" "$sha"
    updated=$((updated+1))
  done < <(manifest_entries)

  log "apply done: $updated module(s) updated, $skipped skipped"
  [ "$DRY_RUN" = 1 ] || echo "  next: review 'git status', then commit gitlink and manifest together"
}

cmd_check() {
  local rc=0 name path ref commit url gl head sha
  while IFS='|' read -r name path ref commit url; do
    [ -n "$name" ] || continue
    if [ -z "$ref" ]; then bad "$name: no ref in manifest"; rc=1; continue; fi
    if ! is_full_sha "$commit"; then
      bad "$name: commit '$commit' is not a 40-hex sha (run apply)"; rc=1
    fi

    if [ "$SUBMODULES" = 1 ]; then
      gl=$(gitlink_of "$path")
      if [ -z "$gl" ]; then
        bad "$name: no gitlink for $path in the index"; rc=1
      elif [ "${gl:0:12}" != "${commit:0:12}" ]; then
        bad "$name: gitlink ${gl:0:12} != manifest commit ${commit:0:12}"; rc=1
      else
        ok "$name: gitlink matches manifest (${commit:0:12})"
        if [ -n "$(head_gitlink_of "$path")" ] && [ "$gl" != "$(head_gitlink_of "$path")" ]; then
          warn "$name: gitlink change is staged but not committed yet"
        fi
      fi
      if [ -e "$path/.git" ]; then
        head=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
        if [ -n "$head" ] && [ "$head" != "$commit" ]; then
          bad "$name: work tree HEAD ${head:0:12} != manifest commit ${commit:0:12} (run apply)"; rc=1
        fi
        if sha=$(resolve_in_dir "$path" "$ref" 2>/dev/null); then
          [ "$sha" = "$commit" ] || { bad "$name: ref '$ref' -> ${sha:0:12}, manifest says ${commit:0:12}"; rc=1; }
        else
          warn "$name: ref '$ref' not resolvable locally, ref/commit cross-check skipped"
        fi
      else
        warn "$name: submodule not initialized, work tree checks skipped"
      fi
    else
      # sources repo: verify the ref still resolves to the recorded commit (needs network)
      if sha=$(resolve_remote "$url" "$ref" 2>/dev/null); then
        if [ "$sha" = "$commit" ]; then
          ok "$name: ref '$ref' -> ${commit:0:12}"
        else
          bad "$name: ref '$ref' -> ${sha:0:12}, manifest says ${commit:0:12} (tag moved upstream?)"; rc=1
        fi
      else
        warn "$name: cannot reach $url, only the sha format was checked"
      fi
    fi
  done < <(manifest_entries)

  if [ "$rc" = 0 ]; then log "BASELINE_CHECK_OK"; else warn "BASELINE_CHECK_FAILED"; fi
  return $rc
}

# ---------------------------------------------------------------- entry point
DRY_RUN=0
CMD="${1:-}"; shift || true
MODULE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --records) RECORDS_ONLY=1; shift ;;
    --module)  MODULE="${2:?--module requires a value}"; shift 2 ;;
    *)         die "unknown option: $1" ;;
  esac
done

case "$CMD" in
  status) cmd_status ;;
  apply)  cmd_apply "$MODULE" ;;
  check)  cmd_check ;;
  -h|--help|"") awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown command: $CMD (expected status|apply|check)" ;;
esac
