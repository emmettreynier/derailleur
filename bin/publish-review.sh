#!/usr/bin/env bash
# publish-review.sh — copy a ready PR's human-readable output (a rendered Quarto book,
# a single .md report, …) from its worktree to a standard review folder the operator
# can open on the laptop (issue #98).
#
# WHY: work done on the DGX renders output that exists only on the DGX. The DGX has no
# Dropbox client, only an rclone remote, so the manifest names the destination in an
# optional `review_dest:` scalar (e.g. `dropbox:projects/<area>-projects/<project>/review`).
# The laptop's Dropbox client then syncs `<review_dest>/pr-<n>/` down. On a machine whose
# worktrees are already local (the laptop) the key is left unset and this is a no-op.
#
# WHO DECIDES WHAT: the interactive orchestrator chooses the paths, by reading the PR's
# results-summary "Key outputs"; this script fixes HOW and WHERE. It is never called from
# the dispatch path (workers, checkers, the autonomous loop).
#
# REPLACING, NOT MERGING: each path is published with `rclone sync -L` (directory) or
# `rclone copyto -L` (file), so a file dropped in a later round does not survive a
# republish. `-L` follows symlinks, which is why any path at or under `data/` is refused:
# it would copy the linked raw tree into Dropbox.
#
# CLEANUP: bin/worktree-prune.sh purges `<review_dest>/pr-<n>` when it removes the
# worktree of a MERGED PR. A PR closed without merging keeps its worktree, and its
# review folder persists with it.
#
# Usage: publish-review.sh <slug> <pr#> <path>... [--dry-run]
#   <path>     relative to the PR's worktree root (e.g. notes/_book, report.md)
#   --dry-run  print every rclone command it would run; run none
#
# Exit: 0 at least one path published (or review_dest unset — nothing to do)
#       1 nothing published · unknown slug · no worktree · gh/rclone unavailable
#       2 usage (no paths, non-numeric PR#, a rejected path — including a path or nested
#         symlink whose real path is outside the worktree or under its data/)
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: publish-review.sh <slug> <pr#> <path>... [--dry-run]" >&2
  echo "  <path> is relative to the PR's worktree; absolute, '..' and data/ paths are refused" >&2
  exit 2
}

DRY=0
POS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) usage ;;
    --*) echo "publish-review: unknown flag: $a" >&2; usage ;;
    *) POS+=("$a") ;;
  esac
done
# Guard the count BEFORE indexing POS: an empty array expanded under `set -u` aborts
# bash 3.2 (CLAUDE.md).
[ "${#POS[@]}" -ge 3 ] || usage
SLUG="${POS[0]}" PR="${POS[1]}"
case "$PR" in ''|*[!0-9]*) usage ;; esac
PATHS=("${POS[@]:2}")

# --- path validation (before any gh/rclone call) ------------------------------------
# norm_path <p> — drop leading `./` and trailing `/`, so `./data/raw/` is judged as
# `data/raw`. Prints the normalized form.
norm_path() {
  local p="$1"
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
  printf '%s' "$p"
}
CLEAN=()
for p in "${PATHS[@]}"; do
  n="$(norm_path "$p")"
  case "$p" in
    /*)   echo "publish-review: refused '$p': absolute path (give it relative to the worktree)" >&2; exit 2 ;;
  esac
  case "$p" in
    *..*) echo "publish-review: refused '$p': contains '..'" >&2; exit 2 ;;
  esac
  case "$n" in
    ''|.) echo "publish-review: refused '$p': names the whole worktree (pick the rendered output)" >&2; exit 2 ;;
    data|data/*)
      echo "publish-review: refused '$p': under data/ (rclone -L would copy the linked data tree)" >&2; exit 2 ;;
  esac
  CLEAN+=("$n")
done

# --- manifest -----------------------------------------------------------------------
# Scalar reader: a mirror of the launchers' yml() grammar (first `^key: value` line wins,
# a ` #comment` tail is stripped, one layer of quotes dropped). Keep it in step with
# bin/launch-worker.sh / bin/launch-checker.sh — see CLAUDE.md.
yml() { sed -nE "s/^$2:[[:space:]]*(.+)/\1/p" "$1" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
expand() { eval echo "$1"; }   # ~ and $VAR expansion for path fields

# review_dest_of <manifest> — the trimmed review_dest value, or empty. On top of the
# mirrored grammar: surrounding whitespace is trimmed and a bare-comment value
# (`review_dest: # unset`) reads as unset, so neither can masquerade as a destination.
review_dest_of() {
  local v
  v="$(yml "$1" review_dest)"
  v="$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in '#'*) v="" ;; esac
  while [ "${v%/}" != "$v" ]; do v="${v%/}"; done
  printf '%s' "$v"
}

MANIFEST="$ORCH/projects/$SLUG.yml"
[ -f "$MANIFEST" ] || { echo "publish-review: no onboarded repo '$SLUG' (expected projects/$SLUG.yml)" >&2; exit 1; }
REPO="$(yml "$MANIFEST" repo)"
[ -n "$REPO" ] || { echo "publish-review: projects/$SLUG.yml has no repo: field" >&2; exit 1; }
WORKTREES_DIR="$(expand "$(yml "$MANIFEST" worktrees_dir)")"
[ -n "$WORKTREES_DIR" ] || { echo "publish-review: projects/$SLUG.yml has no worktrees_dir: field" >&2; exit 1; }
DEST="$(review_dest_of "$MANIFEST")"

# --- worktree: <worktrees_dir>/<headRefName> ------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "publish-review: gh not found" >&2; exit 1; }
HEAD="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName 2>/dev/null || true)"
[ -n "$HEAD" ] || { echo "publish-review: could not resolve the head branch of $REPO#$PR (gh pr view failed or returned nothing)" >&2; exit 1; }
case "$HEAD" in
  /*|*..*) echo "publish-review: refused head branch '$HEAD' for $REPO#$PR" >&2; exit 1 ;;
esac
WT="$WORKTREES_DIR/$HEAD"
[ -d "$WT" ] || { echo "publish-review: no worktree for $REPO#$PR at $WT" >&2; exit 1; }

if [ -z "$DEST" ]; then
  echo "no review_dest for $SLUG; output is already local at $WT"
  exit 0
fi

# --- containment: every path, and every symlink under it, must stay in the worktree ----
# `rclone -L` follows symlinks, so the lexical checks above are not enough: a link INSIDE
# a published directory (`report/link -> ../../../outside`) was verified on the DGX to
# upload `outside/` (issue #98). Resolve each existing path and walk it, following links
# the way -L does; refuse (exit 2, naming the link) anything whose real path lies outside
# the worktree or under its data/ — before any rclone call, --dry-run included.
command -v python3 >/dev/null 2>&1 || { echo "publish-review: python3 not found; cannot check paths for escaping symlinks" >&2; exit 1; }
crc=0
python3 - "$WT" "${CLEAN[@]}" <<'PY' || crc=$?
import os, sys
wt = sys.argv[1]
root = os.path.realpath(wt)
# data/ is refused whether it is a real directory in the worktree or a link to the data tree
banned = {os.path.join(root, "data"), os.path.realpath(os.path.join(wt, "data"))}

def under(p, d):
    return p == d or p.startswith(d.rstrip(os.sep) + os.sep)

def bad(real):
    if not under(real, root):
        return "resolves outside the worktree"
    if any(under(real, d) for d in banned):
        return "resolves under data/"
    return None

def refuse(shown, link, real, why):
    print("publish-review: refused '%s': %s %s (%s)" % (shown, link, why, real), file=sys.stderr)
    sys.exit(2)

for rel in sys.argv[2:]:
    src = os.path.join(wt, rel)
    if not os.path.lexists(src):
        continue                      # reported as `skip <path>: not found` later
    real = os.path.realpath(src)
    why = bad(real)
    if why:
        refuse(rel, rel, real, why)
    if not os.path.isdir(real):
        continue
    seen = set()
    for d, dirs, files in os.walk(src, followlinks=True):
        rd = os.path.realpath(d)
        if rd in seen:                # a link cycle: do not walk it twice
            dirs[:] = []
            continue
        seen.add(rd)
        for name in dirs + files:
            f = os.path.join(d, name)
            if os.path.islink(f):
                why = bad(os.path.realpath(f))
                if why:
                    refuse(rel, os.path.relpath(f, wt), os.path.realpath(f), why)
PY
[ "$crc" = 0 ] || exit "$crc"

if [ "$DRY" = 0 ] && ! command -v rclone >/dev/null 2>&1; then
  echo "publish-review: rclone not found; cannot publish to $DEST" >&2; exit 1
fi

# --- publish ------------------------------------------------------------------------
TARGET="$DEST/pr-$PR"
PUBLISHED=0 FAILED=0
for p in "${CLEAN[@]}"; do
  src="$WT/$p"
  if [ -d "$src" ]; then
    verb=sync
  elif [ -e "$src" ]; then
    verb=copyto
  else
    echo "skip $p: not found"; continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] rclone $verb -L $src $TARGET/$p"
    PUBLISHED=$((PUBLISHED+1))
  elif rclone "$verb" -L "$src" "$TARGET/$p"; then
    echo "published $p -> $TARGET/$p"
    PUBLISHED=$((PUBLISHED+1))
  else
    echo "⚠ rclone $verb failed for $p (rclone exit nonzero; see its output above)"
    FAILED=$((FAILED+1))
  fi
done

if [ "$PUBLISHED" -eq 0 ]; then
  echo "publish-review: nothing published for $REPO#$PR"
  exit 1
fi

case "$DEST" in
  dropbox:*) LAPTOP="~/Dropbox/${DEST#dropbox:}/pr-$PR/" ;;
  *)         LAPTOP="" ;;
esac
LAPTOP="${LAPTOP//\/\//\/}"   # a `dropbox:/x` destination must not render as ~/Dropbox//x
pre=""; [ "$DRY" = 1 ] && pre="[dry-run] would be "
if [ -n "$LAPTOP" ]; then
  echo "${pre}on the laptop at: $LAPTOP"
else
  echo "${pre}at $TARGET/ (not a dropbox: remote, so no laptop path to report)"
fi
[ "$FAILED" -eq 0 ] || echo "publish-review: $FAILED path(s) failed to publish (see ⚠ above)"
exit 0
