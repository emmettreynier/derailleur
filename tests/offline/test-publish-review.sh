#!/usr/bin/env bash
# test-publish-review.sh (offline) — bin/publish-review.sh, issue #98.
#
# `dr publish-review <slug> <pr#> <path>... [--dry-run]` copies a ready PR's rendered
# output from its worktree to `<review_dest>/pr-<n>/<path>`. Everything runs against a
# throwaway sandbox with `gh` and `rclone` PATH shims that LOG every call, so the test
# can assert both what was run and — just as important — that NOTHING was run (the
# unset-review_dest case, the rejections, --dry-run).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/publish-review.sh" "bin/publish-review.sh present" \
  "The review publisher is missing from bin/."

SB="$(new_sandbox)"
sandbox_copy_script "$SB" publish-review
PRV="$SB/bin/publish-review.sh"

# --- shims ----------------------------------------------------------------------------
# gh:     logs argv; `pr view` prints $SHIM_HEAD (default issue-7); exit $SHIM_GH_RC.
# rclone: logs argv; exit $SHIM_RCLONE_RC (default 0).
SHIMS="$(sandbox_tmp)"
LOGS="$(sandbox_tmp)"
cat >"$SHIMS/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOGS/gh.log"
[ "\${SHIM_GH_RC:-0}" = 0 ] || exit "\$SHIM_GH_RC"
case "\$1 \$2" in "pr view") printf '%s\n' "\${SHIM_HEAD:-issue-7}" ;; esac
exit 0
SH
cat >"$SHIMS/rclone" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOGS/rclone.log"
exit "\${SHIM_RCLONE_RC:-0}"
SH
chmod +x "$SHIMS/gh" "$SHIMS/rclone"
export PATH="$SHIMS:$PATH"
reset_logs() { : >"$LOGS/gh.log"; : >"$LOGS/rclone.log"; }
calls() { wc -l <"$LOGS/$1.log" | tr -d ' '; }

# --- fixture: two slugs, one with review_dest, one without -----------------------------
# The destination is a SYNTHETIC placeholder (no real Dropbox path in the tracked diff).
WTS="$SB/data/worktrees"
WT="$WTS/issue-7"
mkdir -p "$WT/notes/_book/sub" "$WT/data/raw"
echo '<html>book</html>' >"$WT/notes/_book/index.html"
echo 'page' >"$WT/notes/_book/sub/page.html"
echo '# report' >"$WT/report.md"
DEST='dropbox:example-area/demo/review'
cat >"$SB/projects/demo.yml" <<YML
repo: owner/demo
worktrees_dir: $WTS
review_dest: "$DEST/"   # trailing slash + quotes + comment: the scalar grammar's three rules
YML
cat >"$SB/projects/local.yml" <<YML
repo: owner/local
worktrees_dir: $WTS
# review_dest: dropbox:never/read    (a commented-out key is unset)
YML

# ===========================================================================
# usage — exit 2, no gh / rclone call
# ===========================================================================
reset_logs
rc=0; out="$("$PRV" demo 12 2>&1)" || rc=$?
assert_rc 2 "$rc" "no paths exits 2" "publish-review needs at least one <path>."
assert_contains "$out" "usage: publish-review.sh <slug> <pr#> <path>..." "no paths prints usage"
rc=0; out="$("$PRV" demo 12 --dry-run 2>&1)" || rc=$?
assert_rc 2 "$rc" "no paths with --dry-run still exits 2"
rc=0; out="$("$PRV" demo abc notes/_book 2>&1)" || rc=$?
assert_rc 2 "$rc" "a non-numeric PR# exits 2"
assert_contains "$out" "usage:" "a non-numeric PR# prints usage"
rc=0; out="$("$PRV" 2>&1)" || rc=$?
assert_rc 2 "$rc" "no arguments at all exits 2 (no empty-array abort under bash 3.2)"
assert_eq 0 "$(calls gh)" "usage errors make zero gh calls"
assert_eq 0 "$(calls rclone)" "usage errors make zero rclone calls"

# ===========================================================================
# path rejections — exit 2 naming the path, before any gh / rclone call
# ===========================================================================
for bad in /etc/passwd ../other notes/../../x data data/ data/raw ./data/raw/ ./data; do
  reset_logs
  rc=0; out="$("$PRV" demo 12 notes/_book "$bad" 2>&1)" || rc=$?
  assert_rc 2 "$rc" "path '$bad' is rejected with exit 2" \
    "Absolute, '..' and data/ paths must be refused; -L would follow data/ into the raw tree."
  assert_contains "$out" "refused '$bad'" "the rejection names '$bad'"
  assert_eq 0 "$(calls rclone)" "a rejected '$bad' publishes nothing, not even the valid path"
  assert_eq 0 "$(calls gh)" "a rejected '$bad' is caught before any gh call"
done
reset_logs
rc=0; out="$("$PRV" demo 12 dataset/notes.md 2>&1)" || rc=$?
assert_not_contains "$out" "refused" "a path merely starting with 'data' (dataset/) is not rejected"

# ===========================================================================
# unknown slug / gh failure / missing worktree — exit 1
# ===========================================================================
rc=0; out="$("$PRV" nosuch 12 notes/_book 2>&1)" || rc=$?
assert_rc 1 "$rc" "an unknown slug exits 1"
assert_contains "$out" "projects/nosuch.yml" "an unknown slug names the expected manifest"

reset_logs
rc=0; out="$(SHIM_GH_RC=1 "$PRV" demo 12 notes/_book 2>&1)" || rc=$?
assert_rc 1 "$rc" "a failing gh exits 1"
assert_eq 0 "$(calls rclone)" "a failing gh makes zero rclone calls"

reset_logs
rc=0; out="$(SHIM_HEAD=issue-99 "$PRV" demo 12 notes/_book 2>&1)" || rc=$?
assert_rc 1 "$rc" "a missing worktree exits 1"
assert_contains "$out" "$WTS/issue-99" "the missing-worktree error names <worktrees_dir>/<headRefName>"
assert_eq 0 "$(calls rclone)" "a missing worktree makes zero rclone calls"

# The worktree is resolved from the PR's headRefName.
reset_logs
"$PRV" demo 12 notes/_book >/dev/null 2>&1 || true
assert_contains "$(cat "$LOGS/gh.log")" "pr view 12 -R owner/demo --json headRefName" \
  "the worktree is resolved via gh pr view <pr#> --json headRefName"

# ===========================================================================
# review_dest unset — the local no-op, zero rclone calls
# ===========================================================================
reset_logs
rc=0; out="$("$PRV" local 12 notes/_book report.md 2>&1)" || rc=$?
assert_rc 0 "$rc" "review_dest unset exits 0"
assert_eq "no review_dest for local; output is already local at $WT" "$out" \
  "review_dest unset prints exactly the already-local line"
assert_eq 0 "$(calls rclone)" "review_dest unset makes zero rclone calls"
reset_logs
rc=0; out="$("$PRV" local 12 notes/_book --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "review_dest unset with --dry-run exits 0"
assert_eq 0 "$(calls rclone)" "review_dest unset with --dry-run makes zero rclone calls"

# ===========================================================================
# publish — sync -L for a directory, copyto -L for a file, into <dest>/pr-<n>/<path>
# ===========================================================================
reset_logs
rc=0; out="$("$PRV" demo 12 notes/_book report.md 2>&1)" || rc=$?
RL="$(cat "$LOGS/rclone.log")"
assert_rc 0 "$rc" "publishing a directory and a file exits 0"
assert_eq 2 "$(calls rclone)" "one rclone call per published path"
assert_contains "$RL" "sync -L $WT/notes/_book $DEST/pr-12/notes/_book" \
  "a directory is published with rclone sync -L (replacing, so stale files go)"
assert_contains "$RL" "copyto -L $WT/report.md $DEST/pr-12/report.md" \
  "a file is published with rclone copyto -L"
assert_not_contains "$RL" "review//" "review_dest's trailing slash does not double up"
assert_contains "$out" "on the laptop at: ~/Dropbox/example-area/demo/review/pr-12/" \
  "the laptop path maps dropbox:<rest> to ~/Dropbox/<rest>/pr-<n>/"

# A trailing slash / leading ./ on the path is normalized, not passed through.
reset_logs
"$PRV" demo 12 ./notes/_book/ >/dev/null 2>&1
assert_contains "$(cat "$LOGS/rclone.log")" "sync -L $WT/notes/_book $DEST/pr-12/notes/_book" \
  "./notes/_book/ is normalized to notes/_book"

# --- a missing path is skipped; the rest still publish ----------------------------------
reset_logs
rc=0; out="$("$PRV" demo 12 nope.html notes/_book 2>&1)" || rc=$?
assert_rc 0 "$rc" "one missing + one present path exits 0"
assert_contains "$out" "skip nope.html: not found" "a missing path prints skip <path>: not found"
assert_eq 1 "$(calls rclone)" "the missing path is not handed to rclone; the present one is"

reset_logs
rc=0; out="$("$PRV" demo 12 nope.html gone/ 2>&1)" || rc=$?
assert_rc 1 "$rc" "no path published exits 1"
assert_contains "$out" "skip gone: not found" "every missing path is reported"
assert_eq 0 "$(calls rclone)" "all-missing makes zero rclone calls"
assert_not_contains "$out" "on the laptop at" "no laptop path is printed when nothing was published"

# --- an rclone failure is not counted as published --------------------------------------
reset_logs
rc=0; out="$(SHIM_RCLONE_RC=5 "$PRV" demo 12 notes/_book 2>&1)" || rc=$?
assert_rc 1 "$rc" "a failed rclone on the only path exits 1"
assert_contains "$out" "⚠ rclone sync failed for notes/_book" "a failed rclone is reported by path"

# ===========================================================================
# --dry-run — prints every rclone command, runs none
# ===========================================================================
reset_logs
rc=0; out="$("$PRV" demo 12 notes/_book report.md missing.md --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "--dry-run exits 0"
assert_eq 0 "$(calls rclone)" "--dry-run runs no rclone command"
assert_contains "$out" "[dry-run] rclone sync -L $WT/notes/_book $DEST/pr-12/notes/_book" \
  "--dry-run prints the directory sync"
assert_contains "$out" "[dry-run] rclone copyto -L $WT/report.md $DEST/pr-12/report.md" \
  "--dry-run prints the file copyto"
assert_contains "$out" "skip missing.md: not found" "--dry-run still reports a missing path"
assert_contains "$out" "~/Dropbox/example-area/demo/review/pr-12/" \
  "--dry-run still reports the laptop path"
# --dry-run anywhere in argv, not only last.
reset_logs
rc=0; "$PRV" --dry-run demo 12 report.md >/dev/null 2>&1 || rc=$?
assert_rc 0 "$rc" "--dry-run is accepted before the positionals"
assert_eq 0 "$(calls rclone)" "--dry-run before the positionals still runs no rclone"

# ===========================================================================
# a non-dropbox destination publishes but reports no laptop path
# ===========================================================================
cat >"$SB/projects/other.yml" <<YML
repo: owner/other
worktrees_dir: $WTS
review_dest: s3:bucket/review
YML
reset_logs
rc=0; out="$("$PRV" other 3 report.md 2>&1)" || rc=$?
assert_rc 0 "$rc" "a non-dropbox review_dest publishes and exits 0"
assert_contains "$(cat "$LOGS/rclone.log")" "copyto -L $WT/report.md s3:bucket/review/pr-3/report.md" \
  "a non-dropbox review_dest is used verbatim"
assert_contains "$out" "not a dropbox: remote" "a non-dropbox review_dest says it has no laptop path"

# ===========================================================================
# the two review_dest readers stay identical (publish-review builds the publish target,
# worktree-prune the purge target, from the same value) — see CLAUDE.md
# ===========================================================================
reader() { awk '/^review_dest_of\(\) \{/{on=1} on{print} on&&/^\}/{exit}' "$1"; }
R1="$(reader "$REPO_ROOT/bin/publish-review.sh")"
R2="$(reader "$REPO_ROOT/bin/worktree-prune.sh")"
assert_ne "" "$R1" "publish-review.sh defines review_dest_of()"
assert_eq "$R1" "$R2" "worktree-prune.sh carries an identical review_dest_of()" \
  "Change both copies together: the purge must target the folder publish-review wrote."
