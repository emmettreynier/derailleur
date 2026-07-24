#!/usr/bin/env bash
# test-worktree-prune.sh (offline) — worktree-prune.sh --auto --dry-run in a
# zero-worktree sandbox must exit 0 and NOT abort. This is the regression net for the
# bash-3.2 traps that bit this script before: an empty-array expansion under `set -u`
# and a bare-short-circuit `return` under `set -e` (issue #23) each silently killed
# `--auto`. New offline coverage (issue #31).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/worktree-prune.sh" "bin/worktree-prune.sh present" \
  "The worktree pruner is missing from bin/."

SB="$(new_sandbox)"
sandbox_copy_script "$SB" worktree-prune
WT="$SB/bin/worktree-prune.sh"

# Zero onboarded projects, zero worktrees, no ledger — the empty-iteration path.
rc=0; out="$("$WT" --auto --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "worktree-prune --auto --dry-run exits 0 with zero worktrees" \
  "A bash-3.2 empty-array / bare-short-circuit regression re-aborts --auto (issue #23)."
assert_contains "$out" "removed 0, kept 0" "reports removed 0, kept 0 on an empty sandbox" \
  "run_auto must still print its summary when there's nothing to iterate."

# A manifest whose worktrees_dir doesn't exist is skipped without aborting (the
# `[ -d "$worktrees_dir" ] || continue` guard, another empty-iteration path).
write_project_manifest "$SB" zz-empty owner/zz "$SB/data"
cat >>"$SB/projects/zz-empty.yml" <<YML
working_clone: $SB/data/clone
worktrees_dir: $SB/data/does-not-exist
YML
rc=0; out="$("$WT" --auto --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "worktree-prune --auto --dry-run exits 0 with a manifest but no worktrees dir" \
  "A missing worktrees_dir must be skipped, not abort the run."
