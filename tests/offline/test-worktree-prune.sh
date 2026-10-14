#!/usr/bin/env bash
# test-worktree-prune.sh (offline) — worktree-prune.sh --auto --dry-run in a
# zero-worktree sandbox must exit 0 and NOT abort. This is the regression net for the
# bash-3.2 traps that bit this script before: an empty-array expansion under `set -u`
# and a bare-short-circuit `return` under `set -e` (issue #23) each silently killed
# `--auto`. New offline coverage (issue #31).
#
# ALSO covers the dead-tmux-session reaper (issue #53): a dead derail-* session is
# reaped, an ALIVE one is left and reported, a non-derail- session is never touched,
# --dry-run kills nothing, and no tmux server at all is a clean no-op. Those cases need
# tmux and SKIP cleanly without it. They run against a PRIVATE tmux server (see
# TMUX_TMPDIR below) so the suite can never see — let alone kill — a real session.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

# --- private tmux server ------------------------------------------------------
# Socket dir lives under /tmp, NOT under the sandbox root: a unix socket path is capped
# at ~104 chars and macOS's $TMPDIR alone eats half of that. Unset $TMUX so running the
# suite from inside a real tmux session can't confuse the client. The cleanup chains
# into the sandbox's own EXIT trap (a second `trap ... EXIT` would replace it).
TMUX_SOCK_DIR="$(mktemp -d /tmp/drl-tmux.XXXXXX)"
export TMUX_TMPDIR="$TMUX_SOCK_DIR"
unset TMUX TMUX_PANE 2>/dev/null || true
_wtp_cleanup() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$TMUX_SOCK_DIR"
  _sandbox_cleanup
  return 0
}
trap _wtp_cleanup EXIT

assert_file_present "$REPO_ROOT/bin/worktree-prune.sh" "bin/worktree-prune.sh present" \
  "The worktree pruner is missing from bin/."

SB="$(new_sandbox)"
sandbox_copy_script "$SB" worktree-prune
sandbox_copy_script "$SB" dispatch-common   # worktree-prune sources tmux_job_state from it
WT="$SB/bin/worktree-prune.sh"

# Zero onboarded projects, zero worktrees, no ledger — the empty-iteration path.
rc=0; out="$("$WT" --auto --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "worktree-prune --auto --dry-run exits 0 with zero worktrees" \
  "A bash-3.2 empty-array / bare-short-circuit regression re-aborts --auto (issue #23)."
assert_contains "$out" "removed 0, kept 0" "reports removed 0, kept 0 on an empty sandbox" \
  "run_auto must still print its summary when there's nothing to iterate."

# No tmux server has been started on the private socket yet (and tmux may not even be
# installed) — either way the reaper must be a silent no-op, not an error.
assert_not_contains "$out" "tmux:" "no tmux server is a clean no-op (no tmux summary line)" \
  "reap_tmux_sessions must return early when no server answers; see bin/worktree-prune.sh."
assert_not_contains "$out" "no server running" "no tmux server produces no error output" \
  "tmux list-sessions' stderr must be swallowed in reap_tmux_sessions."

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

# ===========================================================================
# tmux reaper (issue #53) — needs tmux; SKIPs cleanly when it's absent.
# ===========================================================================
if ! command -v tmux >/dev/null 2>&1; then
  skip "tmux not installed — skipping the dead-session reaper cases"
else
  DEAD_S=derail-owner-demo-repo-11    # finished job: pane dead, session lingering
  LIVE_S=derail-owner-demo-repo-12    # worker still waiting on real compute
  KEEP_S=zz-not-ours                  # someone else's session — none of our business

  # Stand up the fixture. Every step is allowed to fail into a SKIP rather than a FAIL:
  # a CI host can have the tmux binary but no environment a server will start in, and a
  # tmux build that ignores remain-on-exit would leave no dead session to reap. Neither
  # is a defect in the code under test.
  d=""
  if tmux new-session -d -s "$KEEP_S" 'sleep 300' 2>/dev/null \
     && tmux new-session -d -s "$LIVE_S" 'sleep 300' 2>/dev/null \
     && tmux new-session -d -s "$DEAD_S" 'sleep 1' 2>/dev/null; then
    # Mirror tmux-run.sh: create, THEN set remain-on-exit so the finished pane lingers.
    # The command sleeps briefly so the option lands before it exits.
    tmux set-option -w -t "$DEAD_S" remain-on-exit on 2>/dev/null \
      || tmux set-option -t "$DEAD_S" remain-on-exit on 2>/dev/null || true
    # Wait for the short command to finish so the pane is genuinely dead (bounded).
    i=0
    while [ "$i" -lt 40 ]; do
      d="$(tmux list-panes -t "$DEAD_S" -F '#{pane_dead}' 2>/dev/null | head -1 || true)"
      [ "$d" = 1 ] && break
      sleep 0.25; i=$((i+1))
    done
  fi
  if [ "$d" != 1 ]; then
    tmux kill-server 2>/dev/null || true
    skip "no usable private tmux server / no remain-on-exit here — skipping the reaper cases"
  else
    have_session() { tmux has-session -t "$1" 2>/dev/null && echo yes || echo no; }

    # --- --dry-run: reports the dead one, kills nothing --------------------
    rc=0; out="$("$WT" --auto --dry-run 2>&1)" || rc=$?
    dry_dead="$(have_session "$DEAD_S")"
    assert_rc 0 "$rc" "worktree-prune --auto --dry-run exits 0 with tmux sessions present" \
      "The reaper must not abort the run; see reap_tmux_sessions in bin/worktree-prune.sh."
    assert_contains "$out" "would reap tmux $DEAD_S" "--dry-run reports the dead derail-* session" \
      "The DRY branch of reap_tmux_sessions must name what it would kill."
    assert_contains "$out" "would reap 1 dead derail-* sessions, left 1 alive" \
      "--dry-run summary reports both counts" \
      "run_auto's tmux summary line must report reaped + alive counts."
    assert_eq yes "$dry_dead" "--dry-run killed nothing" \
      "--dry-run must report only — no tmux kill-session."

    # --- real run: reaps dead only ----------------------------------------
    rc=0; out="$("$WT" --auto 2>&1)" || rc=$?
    got_dead="$(have_session "$DEAD_S")"
    got_live="$(have_session "$LIVE_S")"
    got_keep="$(have_session "$KEEP_S")"
    tmux kill-server 2>/dev/null || true   # tear down before asserting so nothing leaks

    assert_rc 0 "$rc" "worktree-prune --auto exits 0 with tmux sessions present" \
      "The reaper must not abort the run; see reap_tmux_sessions in bin/worktree-prune.sh."
    assert_eq no "$got_dead" "a DEAD derail-* session is reaped" \
      "reap_tmux_sessions must kill sessions whose pane_dead=1."
    assert_eq yes "$got_live" "an ALIVE derail-* session is left alone" \
      "Killing a live session destroys in-progress compute — the whole point of issue #53."
    assert_eq yes "$got_keep" "a non-derail- session is never touched" \
      "The reaper must match the derail- prefix; other tmux sessions are not its business."
    assert_contains "$out" "reaped tmux $DEAD_S" "the real run names the session it reaped" \
      "reap_tmux_sessions should report each kill."
    assert_contains "$out" "keep tmux $LIVE_S" "the live session is reported, not silently skipped" \
      "An alive session must be surfaced so the operator knows why it survived."
    assert_not_contains "$out" "$KEEP_S" "the non-derail- session is not even mentioned" \
      "The prefix filter must skip foreign sessions before probing them."
    assert_contains "$out" "reaped 1 dead derail-* sessions, left 1 alive" \
      "the summary line reports both counts" \
      "run_auto's tmux summary must read like 'removed N, kept M' — see issue #53."
  fi
fi

# ===========================================================================
# review-folder purge on merged removal (issue #98)
#
# A slug with `review_dest:` set gets `rclone purge <review_dest>/pr-<merged PR#>` when
# --auto removes its merged worktree; a slug without it makes zero rclone calls and
# prints exactly what it printed before the key existed. Real git worktrees (a bare
# origin + clone, each issue-N branch pushed so it is clean and not ahead) and `gh` /
# `rclone` PATH shims that log every call. The destination is a SYNTHETIC placeholder.
# ===========================================================================
GITC=(-c user.name=derailleur-test -c user.email=test@example.invalid -c commit.gpgsign=false)
SHIMS="$(sandbox_tmp)"; LOGS="$(sandbox_tmp)"
# gh: `pr list --head issue-N` -> merged PR (100+N) unless N is listed in $LOGS/unmerged;
#     `issue view` -> CLOSED.
cat >"$SHIMS/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOGS/gh.log"
case "\$1 \$2" in
  "pr list")
    h=""; prev=""
    for a in "\$@"; do [ "\$prev" = --head ] && h="\$a"; prev="\$a"; done
    n="\${h#issue-}"
    grep -qx "\$n" "$LOGS/unmerged" 2>/dev/null || echo \$((100 + n)) ;;
  "issue view") echo CLOSED ;;
esac
exit 0
SH
# rclone: logs argv; a purge of .../pr-<n> exits with the code in $LOGS/rc-<n> (if any),
# printing rclone's own wording for the missing-directory case.
cat >"$SHIMS/rclone" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOGS/rclone.log"
t="\${!#}"; n="\${t##*/pr-}"
rc=0; [ -f "$LOGS/rc-\$n" ] && rc="\$(cat "$LOGS/rc-\$n")"
case "\$rc" in
  0) ;;
  3) echo "ERROR : Attempt 1/3 failed with 1 errors and: directory not found" >&2 ;;
  *) echo "ERROR : Failed to purge: permission denied" >&2 ;;
esac
exit "\$rc"
SH
chmod +x "$SHIMS/gh" "$SHIMS/rclone"
calls() { [ -f "$LOGS/$1.log" ] && wc -l <"$LOGS/$1.log" | tr -d ' ' || echo 0; }
reset_logs() { : >"$LOGS/gh.log"; : >"$LOGS/rclone.log"; rm -f "$LOGS"/rc-* "$LOGS/unmerged"; }

# build_project <orch> <slug> <issue#>... — a clone + worktrees dir for <slug> under <orch>,
# one pushed, clean issue-N worktree per number, and its manifest (no review_dest).
build_project() {
  local orch="$1" slug="$2" base n; shift 2
  base="$orch/data/$slug"
  mkdir -p "$base/wt"
  git init -q --bare "$base/origin.git"
  git clone -q "$base/origin.git" "$base/clone" 2>/dev/null
  git "${GITC[@]}" -C "$base/clone" commit -q --allow-empty -m init
  git -C "$base/clone" push -q origin HEAD 2>/dev/null
  for n in "$@"; do
    git -C "$base/clone" worktree add -q -b "issue-$n" "$base/wt/issue-$n" 2>/dev/null
    git -C "$base/wt/issue-$n" push -q -u origin "issue-$n" 2>/dev/null
  done
  cat >"$orch/projects/$slug.yml" <<YML
repo: owner/$slug
working_clone: $base/clone
worktrees_dir: $base/wt
YML
}

RDEST='dropbox:example-area/rev/review'
SBR="$(new_sandbox)"
sandbox_copy_script "$SBR" worktree-prune
sandbox_copy_script "$SBR" dispatch-common
build_project "$SBR" rev 1 2 3 9
echo "review_dest: $RDEST   # synthetic" >>"$SBR/projects/rev.yml"
build_project "$SBR" plain 5
WTR="$SBR/bin/worktree-prune.sh"

# --- --dry-run: reports `would purge`, runs no rclone, removes nothing --------------------
reset_logs; echo 9 >"$LOGS/unmerged"
rc=0; out="$(PATH="$SHIMS:$PATH" "$WTR" --auto --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "review: --auto --dry-run exits 0 with review_dest set"
for n in 1 2 3; do
  assert_contains "$out" "would purge $RDEST/pr-10$n" "review: --dry-run reports would purge pr-10$n"
done
assert_not_contains "$out" "pr-109" "review: --dry-run never purges an UNMERGED PR's folder"
assert_not_contains "$out" "pr-105" "review: --dry-run purges nothing for the slug without review_dest"
assert_eq 0 "$(calls rclone)" "review: --dry-run runs no rclone purge"
assert_contains "$out" "worktree-prune: review: would purge 3 pr-* folder(s)" \
  "review: --dry-run summary reports the would-purge count"
assert_file_present "$SBR/data/rev/wt/issue-1" "review: --dry-run removes no worktree"

# --- real run: purge on merged removal, missing folder silent, failed purge warns -------
reset_logs; echo 9 >"$LOGS/unmerged"
echo 3 >"$LOGS/rc-102"   # pr-102 was never published: rclone's "directory not found"
echo 1 >"$LOGS/rc-103"   # pr-103's purge fails outright
rc=0; out="$(PATH="$SHIMS:$PATH" "$WTR" --auto 2>&1)" || rc=$?
RL="$(cat "$LOGS/rclone.log")"
assert_rc 0 "$rc" "review: a failed purge leaves the exit status at 0" \
  "purge_review must never fail the run; see bin/worktree-prune.sh."
assert_contains "$RL" "purge $RDEST/pr-101" "review: removing merged PR#101's worktree purges <review_dest>/pr-101"
assert_eq "purge $RDEST/pr-101
purge $RDEST/pr-102
purge $RDEST/pr-103" "$(sort <<<"$RL")" \
  "review: exactly one purge per merged removal, each exactly <review_dest>/pr-<n> — nothing wider, nothing for the other slug"
assert_contains "$out" "purged review folder $RDEST/pr-101" "review: a successful purge is reported"
assert_not_contains "$out" "pr-102" "review: a missing folder (rclone exit 3) is a silent no-op"
assert_contains "$out" "⚠ review purge failed for $RDEST/pr-103 (rclone exit 1): ERROR : Failed to purge: permission denied" \
  "review: a failed purge prints a warning naming the folder"
assert_file_absent "$SBR/data/rev/wt/issue-3" "review: the worktree is still removed when its purge fails"
assert_file_absent "$SBR/data/rev/wt/issue-2" "review: the worktree is removed when its folder was missing"
assert_file_present "$SBR/data/rev/wt/issue-9" "review: an unmerged worktree is kept"
assert_file_absent "$SBR/data/plain/wt/issue-5" "review: the slug without review_dest still has its merged worktree removed"
assert_contains "$out" "worktree-prune: review: purged 1 pr-* folder(s)" \
  "review: the summary tail counts only folders actually purged"

# --- no slug sets review_dest: zero rclone calls, output unchanged from before #98 -------
SBP="$(new_sandbox)"
sandbox_copy_script "$SBP" worktree-prune
sandbox_copy_script "$SBP" dispatch-common
build_project "$SBP" plain 5
reset_logs
SHA5="$(git -C "$SBP/data/plain/clone" rev-parse --short issue-5)"
rc=0; out="$(PATH="$SHIMS:$PATH" "$SBP/bin/worktree-prune.sh" --auto 2>&1)" || rc=$?
assert_rc 0 "$rc" "review: --auto exits 0 with no review_dest anywhere"
assert_eq 0 "$(calls rclone)" "review: a slug without review_dest makes zero rclone calls"
# The pre-#98 output for this fixture, line for line (`Deleted branch` is git's own
# stdout from remove_worktree's `branch -D`; no tmux server on the private socket by
# now, so no tmux line either way).
assert_eq "Deleted branch issue-5 (was $SHA5).
  removed plain issue-5
worktree-prune: removed 1, kept 0" "$out" \
  "review: with no review_dest the prune output is unchanged (no review: line)"
