#!/usr/bin/env bash
# test-verdict-rotation.sh (offline) — a checker dispatch must clear the canonical verdict
# path so a RE-dispatched checker cannot be reported terminal off the previous round's
# verdict (issue #49).
#
# Why this is a test and not `--dry-run` eyeballing: the failure is silent and inverted —
# the *absence* of a file is what makes watch-dispatch.sh honest. If the rotation is
# dropped or "simplified" to nothing, every round-2 checker still dispatches fine, still
# writes its verdict eventually, and nothing in any log complains; the only symptom is that
# watch-dispatch reports the stale verdict within seconds and exits, so a checker that
# crashes before its first write is reported as a clean pass on an unreviewed tree. That is
# precisely the state the merge gate exists to prevent, and this file is the only alarm.
#
# The rotation lives in `rotate_verdict_file` (bin/dispatch-common.sh) so the three
# filesystem cases can be driven directly, with no `claude` boot; the fourth case —
# --dry-run mutates nothing — is driven end-to-end through the real launcher in a throwaway
# sandbox with a stubbed `gh`, the same way test-agent-deny.sh drives it.
#
# A separate file rather than an extension of test-agent-deny.sh (the only other offline
# test that touches launch-checker.sh): that file asserts ONE safety invariant — the
# subagent deny — across four different dispatch surfaces, and verdict-file lifecycle
# shares neither its subject nor its fixtures.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

# The unit under test, sourced straight from the real lib (no copy — this is the same file
# both launchers source at dispatch time).
. "$REPO_ROOT/bin/dispatch-common.sh"

LOGS="$(sandbox_tmp)"
VF="$LOGS/demo-pr-46-verdict.json"
PREV="$LOGS/demo-pr-46-verdict.prev.json"

# --- (a) an existing verdict is moved aside, canonical path gone --------------------
printf '{"verdict":"pass_with_findings","head":"round-1"}' >"$VF"
rotate_verdict_file "$VF"
assert_file_absent "$VF" \
  "rotation removes the canonical verdict path (a new generation starts clean)" \
  "watch-dispatch.sh's terminal_state stats the canonical path before the ledger status — if it survives a dispatch, round 2 reports round 1's verdict instantly (issue #49)."
assert_file_present "$PREV" \
  "rotation keeps the displaced verdict in a .prev.json slot" \
  "The rotation is deliberately a mv, not an rm — see rotate_verdict_file in bin/dispatch-common.sh."
assert_contains "$(cat "$PREV")" '"head":"round-1"' \
  ".prev.json holds the displaced round's content verbatim" \
  "The move must not rewrite or truncate the file."

# --- (b) a second rotation overwrites .prev.json — exactly one prior generation -----
printf '{"verdict":"changes_requested","head":"round-2"}' >"$VF"
rotate_verdict_file "$VF"
assert_contains "$(cat "$PREV")" '"head":"round-2"' \
  "a later rotation overwrites the single .prev.json slot" \
  "One slot only: nothing prunes logs/, and the checker's PR comment is the durable full history (issue #49 non-goals)."
assert_eq 1 "$(ls "$LOGS" | grep -c 'prev' || true)" \
  "rotation leaves exactly one prior generation on disk (no timestamped archive)" \
  "A timestamped archive would accumulate unbounded — rotate_verdict_file must use the single \${vf%.json}.prev.json slot."

# --- (c) no verdict file is a clean no-op (first-ever checker on a PR) --------------
rm -f "$VF" "$PREV"
rc=0
# Run in a `set -e` subshell with the call as the LAST statement: that is the shape that
# aborts a caller silently when a helper ends on a bare `[ -f x ] && mv …` short-circuit
# (the worktree-prune --auto bug, issue #23). It must exit 0 here, not 1.
( set -e; . "$REPO_ROOT/bin/dispatch-common.sh"; rotate_verdict_file "$VF" ) || rc=$?
assert_rc 0 "$rc" \
  "a missing verdict file is a no-op, not an error (and not a bare short-circuit)" \
  "End rotate_verdict_file with an if-block plus explicit 'return 0' — a trailing '[ -f x ] && mv' returns nonzero and aborts the dispatch under set -e (CLAUDE.md, issue #23)."
assert_file_absent "$PREV" \
  "a no-op rotation creates no .prev.json" \
  "Nothing to rotate must mean nothing written."

# --- (d) --dry-run mutates nothing: real launcher, throwaway sandbox, stubbed gh -----
SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" launch-checker
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" config-common
cp -R "$REPO_ROOT/host" "$SB/host"
cp "$REPO_ROOT/briefs/checker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-checker.sh"

# Code-only manifest (raw_resolved == working_clone) so nothing here implies real data.
CLONE="$(sandbox_tmp)"; WTS="$(sandbox_tmp)"
cat >"$SB/projects/verdict-demo.yml" <<YML
repo: test-operator/verdict-demo
working_clone: $CLONE
worktrees_dir: $WTS
data_root: $CLONE
raw_resolved: $CLONE
YML

# Stub `gh` so the launcher's one `gh pr view --json …` resolves offline to an OPEN,
# ready PR closing #49.
GHDIR="$(sandbox_tmp)"
cat >"$GHDIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"isDraft":false,"headRefName":"issue-49","closingIssuesReferences":[{"number":49}],"state":"OPEN"}'
SH
chmod +x "$GHDIR/gh"

SB_VF="$SB/logs/verdict-demo-pr-46-verdict.json"
SB_PREV="$SB/logs/verdict-demo-pr-46-verdict.prev.json"
printf '{"verdict":"pass_with_findings","head":"untouched"}' >"$SB_VF"
before="$(cksum <"$SB_VF")"
rc=0
dry_out="$(PATH="$GHDIR:$PATH" "$SB/bin/launch-checker.sh" verdict-demo 46 --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "launch-checker --dry-run assembles cleanly with a verdict file present" \
  "The dry-run should print its assembled command and exit 0 — see bin/launch-checker.sh."
assert_file_present "$SB_VF" \
  "--dry-run leaves the existing verdict file in place" \
  "A plan-only run mutates nothing — the rotation must sit AFTER the --dry-run exit in bin/launch-checker.sh."
assert_eq "$before" "$(cksum <"$SB_VF")" \
  "--dry-run leaves the verdict file byte-identical" \
  "The dry-run must neither rewrite nor truncate the verdict file."
assert_file_absent "$SB_PREV" \
  "--dry-run creates no .prev.json" \
  "Rotation on a plan-only run would destroy the one local generation while dispatching nothing."
assert_contains "$dry_out" "verdict file" \
  "--dry-run still reports the verdict path it would use" \
  "Keep the resolved verdict path in the dry-run header so an operator can see which file a real run would rotate."

# --- the fix must not have leaked into watch-dispatch.sh ----------------------------
# The issue's precedence non-goal: watch-dispatch keeps reading ONLY the canonical path.
# A `.prev` reference there would mean the stale verdict found a new way back in.
assert_not_contains "$(cat "$REPO_ROOT/bin/watch-dispatch.sh")" '.prev' \
  "watch-dispatch.sh never reads the .prev.json slot" \
  "The rotated file is deliberately invisible to the watcher — its verdict-file-wins precedence stays exactly as-is (issue #49 non-goals)."
assert_contains "$(cat "$REPO_ROOT/bin/launch-checker.sh")" 'rotate_verdict_file "$VERDICT_FILE"' \
  "launch-checker.sh calls the rotation on the real dispatch path" \
  "Both the detached and --foreground paths are covered by the single call before the dispatch branch."
