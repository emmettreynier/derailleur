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
# What it does NOT do (irreducibly manual — see README.md):
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

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../orchestrator
TEMPLATE="$ORCH/templates/project.yml"

note() { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Render templates/project.yml into a manifest: strip the leading HTML-comment header,
# then substitute every {{TOKEN}} from the matching MANIFEST_<TOKEN> env var (same
# {{TOKEN}} convention the launchers use for briefs/*-brief.md). Keeps the manifest
# shape in one tracked file instead of a heredoc buried here.
render_manifest() {
  python3 - "$1" <<'PY'
import os, re, sys
text = re.sub(r'^<!--.*?-->\n', '', open(sys.argv[1]).read(), count=1, flags=re.S)
sys.stdout.write(re.sub(r'{{(\w+)}}',
                        lambda m: os.environ.get('MANIFEST_' + m.group(1), m.group(0)),
                        text))
PY
}

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

command -v gh  >/dev/null 2>&1 || die "gh not found — run bin/install.sh first."
command -v git >/dev/null 2>&1 || die "git not found — run bin/install.sh first."
[ -f "$TEMPLATE" ] || die "manifest template missing: $TEMPLATE"

# --- 1. labels ----------------------------------------------------------------
note "==> labels"
"$ORCH/bin/setup-labels.sh" "$OWNER_REPO"

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
  note "==> scaffolding manifest from template: $MANIFEST"
  # Use literal ~ in the written paths (portable across machines/users); the
  # launchers expand ~ at read time. Reduce an absolute $HOME prefix back to ~.
  clone_w="${CLONE/#$HOME/~}"
  wt_w="${WORKTREES/#$HOME/~}"
  MANIFEST_REPO="$OWNER_REPO" \
  MANIFEST_ARCHETYPE="$ARCHETYPE" \
  MANIFEST_WORKING_CLONE="$clone_w" \
  MANIFEST_WORKTREES_DIR="$wt_w" \
  MANIFEST_DATA_ROOT="$clone_w/data" \
    render_manifest "$TEMPLATE" > "$MANIFEST"
fi

cat <<EOF

project '$SLUG' onboarded.

Before the first real dispatch:
  1. Edit $MANIFEST — set 'project', 'raw_resolved', and confirm paths (TODOs above).
  2. Add the repo to the board + "Needs Me" view (GitHub Projects UI — manual).
  3. dropbox-native only: pin the raw data "Available offline" in Dropbox.
  4. Dry-run a worker:  dr launch-worker $SLUG <issue#> --dry-run
EOF
