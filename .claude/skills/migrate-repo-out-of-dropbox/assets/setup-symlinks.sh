#!/usr/bin/env bash
# Link the gitignored data directories into the Dropbox copy of the project.
#
# This repo holds code only; the large/restricted data live in Dropbox. Run this
# once after cloning (or whenever a link breaks) to recreate the symlinks.
# Idempotent and safe to re-run.
#
# Override the Dropbox location if yours differs:
#   DROPBOX_PROJ=/path/to/projects-parent ./setup-symlinks.sh
#
# ── ADAPTING THIS TEMPLATE ───────────────────────────────────────────────────
# Edit two things for a new repo:
#   1. The path roots just below (DROPBOX_PROJ default, DATA_ROOT, and any extra
#      roots such as a restricted-data source).
#   2. The link list at the bottom — one `link <repo-path> <dropbox-target>` per
#      directory you're symlinking.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Resolve to the directory this script lives in (the repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# $HOME keeps this portable across machines/usernames (coauthors differ).
DROPBOX_PROJ="${DROPBOX_PROJ:-$HOME/Dropbox/projects/<PARENT-DIR>}"
DATA_ROOT="$DROPBOX_PROJ/<DROPBOX-REPO-COPY>"          # the in-Dropbox copy holding the data
EXTSRC_ROOT="$DROPBOX_PROJ/<EXTERNAL-SOURCE>"          # original source an existing symlink pointed at (drop if N/A)

# link <repo-path> <dropbox-target>
link() {
  local linkpath="$1" target="$2"
  if [[ ! -e "$target" ]]; then
    echo "  SKIP  $linkpath  (target missing: $target)"
    return
  fi
  mkdir -p "$(dirname "$linkpath")"
  # If a real (non-symlink) dir is in the way, only remove it when it's empty
  # or holds nothing but a .gitkeep placeholder — never clobber real data.
  if [[ -e "$linkpath" && ! -L "$linkpath" ]]; then
    if [[ -d "$linkpath" ]] && [[ -z "$(ls -A "$linkpath" | grep -v '^.gitkeep$' || true)" ]]; then
      rm -rf "$linkpath"
    else
      echo "  ERROR $linkpath exists and is not an empty placeholder — leaving it alone"
      return
    fi
  fi
  ln -sfn "$target" "$linkpath"
  echo "  OK    $linkpath -> $target"
}

echo "Linking data from: $DATA_ROOT"
# ── EDIT THIS LIST for the target repo ───────────────────────────────────────
link cache                  "$DATA_ROOT/cache"
link data/raw               "$DATA_ROOT/data/raw"
link data/reynier           "$DATA_ROOT/data/reynier"
link dataverse_files        "$DATA_ROOT/dataverse_files"
link output/tables          "$DATA_ROOT/output/tables"
link output/figures         "$DATA_ROOT/output/figures"
# ─────────────────────────────────────────────────────────────────────────────

# Link(s) that point at an external/original source rather than the Dropbox copy
# — e.g. a path that was itself a symlink in the old layout. Drop this block if
# the project has none.
echo "Linking external source from: $EXTSRC_ROOT"
link data/<external-linked-path> "$EXTSRC_ROOT"

echo "Done."
