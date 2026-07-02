#!/usr/bin/env bash
# new-project.sh — onboard ONE repo to the orchestrator (one-time per project).
#
# Reproduces the per-project machine-local setup from the repo + GitHub, never
# from memory. Idempotent: re-running an already-onboarded project is a no-op
# (existing clone fetched, existing manifest left untouched, labels --force'd).
#
# What it does:
#   1. create the orchestrator label set in the repo   (wraps setup-labels.sh)
#   2. ensure an out-of-Dropbox working clone           (git clone if absent)
#   3. create the worktrees dir the launchers add into
#   4. scaffold projects/<slug>.yml         (skipped if it exists)
#
# What it does NOT do (irreducibly manual — see SETUP.md):
#   - add the repo to the board + "Needs Me" view (GitHub Projects UI)
#   - pin raw data "Available offline" (dropbox-native only)
#   - coauthor buy-in for any shared-repo branch protection
#   - fill the manifest's data_root / raw_resolved / board Project — the scaffold
#     leaves TODO markers; a real dispatch needs them set.
#
# Usage:
#   ./new-project.sh <owner/repo> [--archetype git-native|dropbox-native]
#     [--clone <path>] [--worktrees <path>]
#   Defaults: archetype git-native; clone ~/projects/<slug>; worktrees
#   ~/orchestrator/worktrees/<slug>.
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../orchestrator

note() { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- args ---------------------------------------------------------------------
OWNER_REPO="${1:?usage: new-project.sh <owner/repo> [--archetype ...] [--clone ...] [--worktrees ...]}"
shift
case "$OWNER_REPO" in
  */*) : ;;
  *) die "expected <owner/repo>, got '$OWNER_REPO'" ;;
esac
SLUG="${OWNER_REPO##*/}"

ARCHETYPE="git-native"
CLONE=""
WORKTREES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --archetype) ARCHETYPE="$2"; shift ;;
    --clone)     CLONE="$2"; shift ;;
    --worktrees) WORKTREES="$2"; shift ;;
    *) die "unknown arg: $1" ;;
  esac; shift
done
case "$ARCHETYPE" in
  git-native|dropbox-native) : ;;
  *) die "archetype must be git-native or dropbox-native, got '$ARCHETYPE'" ;;
esac
: "${CLONE:=$HOME/projects/$SLUG}"
: "${WORKTREES:=$HOME/orchestrator/worktrees/$SLUG}"

command -v gh  >/dev/null 2>&1 || die "gh not found — run install.sh first."
command -v git >/dev/null 2>&1 || die "git not found — run install.sh first."

# --- 1. labels ----------------------------------------------------------------
note "==> labels"
"$ORCH/setup-labels.sh" "$OWNER_REPO"

# --- 2. working clone (out of Dropbox) ---------------------------------------
note "==> working clone: $CLONE"
if [ -d "$CLONE/.git" ]; then
  note "    exists — fetching"
  git -C "$CLONE" fetch -q origin || warn "fetch failed (offline?)"
else
  [ -e "$CLONE" ] && die "$CLONE exists but is not a git repo — move it aside and re-run."
  mkdir -p "$(dirname "$CLONE")"
  note "    cloning $OWNER_REPO"
  gh repo clone "$OWNER_REPO" "$CLONE"
fi

# --- 3. worktrees dir ---------------------------------------------------------
mkdir -p "$WORKTREES"
note "==> worktrees dir: $WORKTREES"

# --- 4. manifest scaffold -----------------------------------------------------
MANIFEST="$ORCH/projects/$SLUG.yml"
if [ -f "$MANIFEST" ]; then
  note "==> manifest exists, leaving untouched: $MANIFEST"
else
  note "==> scaffolding manifest: $MANIFEST"
  # Use literal ~ in the written paths (portable across machines/users); the
  # launchers expand ~ at read time. Reduce an absolute $HOME prefix back to ~.
  clone_w="${CLONE/#$HOME/~}"
  wt_w="${WORKTREES/#$HOME/~}"
  cat > "$MANIFEST" <<EOF
# Per-project manifest — the onboarding unit. Version-controlled = portable.
# Read by the raw-data deny-hook and the dispatch tooling.
# Scaffolded by new-project.sh — FILL THE TODOs before the first real dispatch.

repo: $OWNER_REPO
project: TODO                   # board "Project" field value (Water/Pesticides/Climate/Energy/Other)
archetype: $ARCHETYPE           # git-native | dropbox-native

# Worker git workspace (outside Dropbox).
working_clone: $clone_w
worktrees_dir: $wt_w

# Data layout — data/ is machine-local and gitignored; the launcher bootstraps
# each worktree with data/raw (READ-ONLY symlink) + writable output dirs.
data_root: $clone_w/data
raw_resolved: TODO              # absolute path data/raw points at (the read-only raw tree)
dropbox_pinned_offline: false  # true (dropbox-native) once raw is pinned "Available offline"

# READ-ONLY. The deny-hook blocks any write/delete whose canonical (symlink-resolved)
# path is under raw/. Paths relative to data_root unless absolute.
raw_paths:
  - raw/         # the entire raw tree, no exceptions

# Writable worker outputs. Documentation + worktree bootstrap (dirs to create);
# the deny-hook is a denylist (block raw_paths, allow the rest), so not enforcement.
output_paths:
  - data/results/
EOF
fi

cat <<EOF

project '$SLUG' onboarded.

Before the first real dispatch:
  1. Edit $MANIFEST — set 'project', 'raw_resolved', and confirm paths (TODOs above).
  2. Add the repo to the board + "Needs Me" view (GitHub Projects UI — manual).
  3. dropbox-native only: pin the raw data "Available offline" in Dropbox.
  4. Dry-run a worker:  ./launch-worker.sh $SLUG <issue#> --dry-run
EOF
