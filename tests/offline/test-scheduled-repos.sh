#!/usr/bin/env bash
# test-scheduled-repos.sh (offline) — the single `scheduled_repos` reader in
# config-common.sh that fronts the per-repo autonomous-dispatch allow-list. New
# coverage for the allow-list PR #33 shipped with none (issue #31 folds it in).
# Fixtures via SCHEDULED_REPOS_FILE; a filled sandbox conf so the guard passes.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

CONFIG_COMMON="$REPO_ROOT/bin/config-common.sh"
SB="$(new_sandbox)"
write_filled_conf "$SB"

# Run scheduled_repos with a given fixture file (path may be absent) under `set -e`,
# in a subshell so nothing leaks. Echoes the helper's stdout.
run_sr() {  # $1 = fixture path
  (
    set -e
    ORCH="$SB" ORCH_DIR="$SB"
    unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
    export SCHEDULED_REPOS_FILE="$1"
    . "$CONFIG_COMMON"
    scheduled_repos
  )
}

FIX="$SB/state/sched-fixture"

# absent file ⇒ empty output
rm -f "$FIX"
out="$(run_sr "$FIX")"
assert_eq "" "$out" "absent allow-list file ⇒ empty output" \
  "scheduled_repos must emit nothing when the file is absent (all-live default)."

# empty file ⇒ empty output
: > "$FIX"
out="$(run_sr "$FIX")"
assert_eq "" "$out" "empty allow-list file ⇒ empty output" \
  "An empty file must read as 'no allow-list' (all-live)."

# non-empty ⇒ only the listed slugs, with comments/blank-lines/whitespace stripped
cat >"$FIX" <<'LIST'
# leading comment line
solar-income

  glyphosate-health
climate-migration  # trailing inline comment

LIST
out="$(run_sr "$FIX")"
expected="solar-income
glyphosate-health
climate-migration"
assert_eq "$expected" "$out" "non-empty ⇒ listed slugs only, comments/blanks/whitespace stripped" \
  "scheduled_repos must strip '# …' comments, blank lines, and leading/trailing whitespace."

# all-comment file ⇒ empty output (exercises the grep-exits-1 || true path)
cat >"$FIX" <<'LIST'
# only comments here
   # indented comment
LIST
out="$(run_sr "$FIX")"
assert_eq "" "$out" "all-comment file ⇒ empty output" \
  "A file of only comments/blanks must read as 'no allow-list'."

# survives a BARE call under `set -e` (bash 3.2): the helper ends in `return 0`, so a
# caller invoking it bare — file absent (early return) or all-comment (grep exits 1) —
# must not abort. We prove it by echoing a sentinel AFTER a bare call in each case.
bare_call() {  # $1 = fixture path
  (
    set -e
    ORCH="$SB" ORCH_DIR="$SB"
    unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
    export SCHEDULED_REPOS_FILE="$1"
    . "$CONFIG_COMMON"
    scheduled_repos >/dev/null    # bare — not in if/&&; would abort on nonzero under set -e
    echo SURVIVED
  )
}
rm -f "$FIX"
assert_eq "SURVIVED" "$(bare_call "$FIX")" "bare call survives set -e with an absent file" \
  "scheduled_repos must end in an explicit return 0 so a bare call isn't aborted (bash 3.2, CLAUDE.md)."
printf '# only comments\n' > "$FIX"
assert_eq "SURVIVED" "$(bare_call "$FIX")" "bare call survives set -e when grep matches nothing" \
  "The trailing || true plus return 0 must absorb grep's exit-1 on an all-comment file."
