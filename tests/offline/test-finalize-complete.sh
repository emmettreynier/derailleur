#!/usr/bin/env bash
# test-finalize-complete.sh (offline) — the completion gate in bin/dispatch-common.sh
# (issue #40): tmux_job_state's pane_dead-based liveness, and assert_finalized's
# per-role reason battery.
#
# Hermetic: every case runs against a throwaway git repo under the sandbox root with
# `gh` and `tmux` PATH SHIMS, so nothing here touches a real repo, a real tmux server,
# or the network. Nothing dispatched, nothing spent.
#
# The regression this file exists to hold: tmux-run.sh sets `remain-on-exit on`, so a
# FINISHED session still answers `has-session`. If liveness were has-session-based,
# every worker that finishes without tearing its session down would be pinned to
# `incomplete-waiting` forever. See the pane_dead=1 case below.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/dispatch-common.sh" "bin/dispatch-common.sh present" \
  "The shared post-run helpers are missing from bin/."

# --- shims --------------------------------------------------------------------
# One shim dir on PATH provides both `tmux` and `gh`. Each reads its behaviour from an
# env var so a single shim covers every case (no rewriting files mid-test):
#   FAKE_TMUX_STATE  absent | alive | dead   (what the fake session reports)
#   FAKE_GH_MODE     nopr | draft | ready | fail | garbage
SHIMS="$(sandbox_tmp)"

cat >"$SHIMS/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) [ "${FAKE_TMUX_STATE:-absent}" != "absent" ] ;;
  list-panes)  case "${FAKE_TMUX_STATE:-absent}" in
                 alive) echo 0 ;;
                 dead)  echo 1 ;;
                 *)     exit 1 ;;
               esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$SHIMS/tmux"

cat >"$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
# Every invocation is appended to $GH_CALLS (when set) so a test can assert what
# finalize_dispatch posted; `gh pr list … --json isDraft` is the only query answered.
if [ -n "${GH_CALLS:-}" ]; then printf '%s\n' "$*" >>"$GH_CALLS"; fi
case "$1 ${2:-}" in
  "pr comment"|"issue comment") exit 0 ;;
esac
case "${FAKE_GH_MODE:-nopr}" in
  nopr)    echo '[]' ;;
  draft)   echo '[{"isDraft":true}]' ;;
  ready)   echo '[{"isDraft":false}]' ;;
  fail)    echo "gh: could not resolve host" >&2; exit 1 ;;
  garbage) echo 'not json at all' ;;
esac
SH
chmod +x "$SHIMS/gh"
export PATH="$SHIMS:$PATH"

# --- a throwaway git repo standing in for a worker worktree --------------------
# `origin` is a plain github.com URL so _worktree_repo derives owner/repo from it, and
# a bare repo gives the branch a real upstream (so `@{u}..HEAD` is answerable).
WT="$(sandbox_tmp)/wt"
BARE="$(sandbox_tmp)/origin.git"
git init -q --bare "$BARE"
git init -q -b issue-7 "$WT"
git -C "$WT" config user.email t@example.com
git -C "$WT" config user.name  "Test Operator"
git -C "$WT" remote add origin "https://github.com/owner/demo.git"
git -C "$WT" remote add upstreamish "$BARE" 2>/dev/null || true
echo hello >"$WT/file.txt"
git -C "$WT" add -A
git -C "$WT" commit -q -m "initial"
# Push to the bare repo and point the branch's upstream at it (via the local path
# remote), so a clean worktree really is "nothing ahead of upstream".
git -C "$WT" push -q upstreamish issue-7
git -C "$WT" branch --set-upstream-to=upstreamish/issue-7 issue-7 >/dev/null 2>&1

LOGS="$(sandbox_tmp)"
# Log basenames MUST keep the real `<slug>-issue-N.log` / `<slug>-pr-N.log` shape:
# that is where assert_finalized derives the issue/PR number from (the signature is
# fixed, so the number is not passed in). A stray suffix silently disables the tmux
# and PR checks.
WORKER_LOG="$LOGS/demo-issue-7.log"
CHECKER_LOG="$LOGS/demo-pr-7.log"
: >"$WORKER_LOG"
: >"$CHECKER_LOG"

# Source a SANDBOXED COPY, not $REPO_ROOT/bin/dispatch-common.sh: record_usage_reset
# resolves its repo root from BASH_SOURCE and writes state/usage-reset there, so
# sourcing the real file would let an offline test park a usage-limit deferral on the
# operator's live checkout.
SB="$(new_sandbox)"
sandbox_copy_script "$SB" dispatch-common
. "$SB/bin/dispatch-common.sh"

# --- tmux_job_state ------------------------------------------------------------
FAKE_TMUX_STATE=absent assert_eq "absent" "$(FAKE_TMUX_STATE=absent tmux_job_state derail-owner-demo-7)" \
  "tmux_job_state: no session -> absent" \
  "has-session returning nonzero must yield 'absent'; see bin/dispatch-common.sh."
assert_eq "alive" "$(FAKE_TMUX_STATE=alive tmux_job_state derail-owner-demo-7)" \
  "tmux_job_state: running pane -> alive" \
  "pane_dead=0 must yield 'alive'; see bin/dispatch-common.sh."
assert_eq "dead" "$(FAKE_TMUX_STATE=dead tmux_job_state derail-owner-demo-7)" \
  "tmux_job_state: finished pane (remain-on-exit) -> dead" \
  "pane_dead=1 must yield 'dead', NOT alive — this is the remain-on-exit regression net."
assert_eq "absent" "$(tmux_job_state '')" \
  "tmux_job_state: empty name -> absent" \
  "An underivable session name must degrade to 'absent', never assert liveness."

# --- assert_finalized: worker --------------------------------------------------
# Clean worktree, pushed, an open READY PR -> finalized (empty reason).
assert_eq "" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker clean + pushed + ready PR -> finalized (no reason)" \
  "A healthy worker must NOT be marked incomplete — this is the false-positive guard."

# The remain-on-exit regression net: session EXISTS but its pane is dead -> still done.
assert_eq "" "$(FAKE_TMUX_STATE=dead FAKE_GH_MODE=ready assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker with a dead (finished) tmux session -> finalized" \
  "Liveness must be pane_dead-based; has-session alone would pin this to incomplete-waiting forever."

# waiting wins over every later check (a live job, even with everything else clean).
assert_eq "waiting" "$(FAKE_TMUX_STATE=alive FAKE_GH_MODE=ready assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker with a live tmux job -> waiting" \
  "A running detached job must be the first-wins reason; see assert_finalized's order."

# uncommitted (tracked change in the worktree).
echo "dirty" >>"$WT/file.txt"
assert_eq "uncommitted" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker with a tracked-file change -> uncommitted" \
  "git status --porcelain -uno must gate completion."
git -C "$WT" checkout -q -- file.txt

# unpushed (a commit ahead of upstream).
echo "more" >>"$WT/file.txt"
git -C "$WT" commit -q -am "ahead"
assert_eq "unpushed" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker with a commit ahead of upstream -> unpushed" \
  "rev-list --count @{u}..HEAD must gate completion."
git -C "$WT" push -q upstreamish issue-7

# nopr / draft (gh shim drives the PR state).
assert_eq "nopr" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=nopr assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker with no open PR on head issue-7 -> nopr" \
  "An empty gh pr list result must assert 'nopr'."
assert_eq "draft" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=draft assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "worker whose PR is still a draft -> draft" \
  "isDraft:true must assert 'draft' — PR-ready is the finalization signal."

# NO false incomplete from a flaky network: a failed or unparseable gh lookup skips
# the nopr/draft checks entirely rather than asserting a reason.
assert_eq "" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=fail assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "gh failure -> no false 'nopr' (checks skipped)" \
  "A non-zero gh must skip the PR checks with a stderr note, never assert incomplete."
assert_eq "" "$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=garbage assert_finalized worker "$WORKER_LOG" "$WT" 2>/dev/null)" \
  "unparseable gh JSON -> no false 'nopr' (checks skipped)" \
  "Unparseable gh output must skip the PR checks, never assert incomplete."
gh_note="$(FAKE_TMUX_STATE=absent FAKE_GH_MODE=fail assert_finalized worker "$WORKER_LOG" "$WT" 2>&1 >/dev/null)"
assert_contains "$gh_note" "skipping nopr/draft checks" "the skipped PR lookup is noted on stderr" \
  "A silently-skipped check is worse than a loud one — keep the stderr note."

# --- assert_finalized: checker --------------------------------------------------
VERDICT="${CHECKER_LOG%.log}-verdict.json"
rm -f "$VERDICT"
assert_eq "noverdict" "$(FAKE_TMUX_STATE=absent assert_finalized checker "$CHECKER_LOG" "$WT" 2>/dev/null)" \
  "checker with no verdict file -> noverdict" \
  "The verdict JSON is the checker's whole deliverable; its absence must gate completion."

printf 'this is not json\n' >"$VERDICT"
assert_eq "noverdict" "$(FAKE_TMUX_STATE=absent assert_finalized checker "$CHECKER_LOG" "$WT" 2>/dev/null)" \
  "checker with an unparseable verdict file -> noverdict" \
  "jq must fail closed here: unparseable == no verdict."

printf '{"notes":"ran out of budget"}\n' >"$VERDICT"
assert_eq "noverdict" "$(FAKE_TMUX_STATE=absent assert_finalized checker "$CHECKER_LOG" "$WT" 2>/dev/null)" \
  "checker with a verdict file lacking .verdict -> noverdict" \
  "An empty/absent .verdict field must count as no verdict."

printf '{"verdict":"pass"}\n' >"$VERDICT"
assert_eq "" "$(FAKE_TMUX_STATE=absent assert_finalized checker "$CHECKER_LOG" "$WT" 2>/dev/null)" \
  "checker with a written verdict -> finalized (no reason)" \
  "A checker that wrote its verdict must NOT be marked incomplete."

# waiting outranks a written verdict: the job is still producing, so this round isn't over.
assert_eq "waiting" "$(FAKE_TMUX_STATE=alive assert_finalized checker "$CHECKER_LOG" "$WT" 2>/dev/null)" \
  "checker with a verdict but a live tmux job -> waiting" \
  "tmux liveness is the first check for BOTH roles; see assert_finalized's order."

# --- classify_result still owns the interrupted path ---------------------------
# A 429 log must stay interrupted-ratelimit: the assertion is consulted ONLY when
# classify_result says `done`, because interrupted-* is already the more informative
# status. (Verified through finalize_dispatch, the real wiring.)
RL_LOG="$LOGS/ratelimit-issue-7.log"
printf '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"Claude AI usage limit reached"}\n' >"$RL_LOG"
assert_eq "interrupted-ratelimit" "$(classify_result "$RL_LOG")" \
  "a 429 log still classifies as interrupted-ratelimit" \
  "classify_result must remain a pure log-JSON parser, unchanged by the completion gate."

LED="$LOGS/ledger-fixture.md"
cat >"$LED" <<LEDGER
- #7 | owner/demo | issue-7 | $RL_LOG | pid 4242 | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
FAKE_TMUX_STATE=alive FAKE_GH_MODE=ready \
  finalize_dispatch "$RL_LOG" "$LED" 4242 "$WT" worker >/dev/null 2>&1 || true
assert_contains "$(cat "$LED")" "status interrupted-ratelimit" \
  "finalize_dispatch keeps interrupted-ratelimit even with a live tmux job" \
  "The assertion must be consulted ONLY when classify_result returns 'done'."

# --- finalize_dispatch records incomplete-<reason> on a clean-but-unfinished run --
DONE_LOG="$LOGS/clean-issue-7.log"
printf '{"type":"result","subtype":"success","is_error":false,"result":"executing in the background"}\n' >"$DONE_LOG"
cat >"$LED" <<LEDGER
- #7 | owner/demo | issue-7 | $DONE_LOG | pid 4243 | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
FAKE_TMUX_STATE=alive FAKE_GH_MODE=ready \
  finalize_dispatch "$DONE_LOG" "$LED" 4243 "$WT" worker >/dev/null 2>&1 || true
assert_contains "$(cat "$LED")" "status incomplete-waiting" \
  "finalize_dispatch records incomplete-waiting for an exit-to-wait" \
  "A clean exit with a live detached job must NOT be recorded as done (issue #40)."

# …and records plain `done` for a genuinely finalized run (the false-positive guard
# at the ledger level, not just the assertion level).
cat >"$LED" <<LEDGER
- #7 | owner/demo | issue-7 | $DONE_LOG | pid 4244 | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready \
  finalize_dispatch "$DONE_LOG" "$LED" 4244 "$WT" worker >/dev/null 2>&1 || true
assert_contains "$(cat "$LED")" "status done" \
  "finalize_dispatch still records plain 'done' for a healthy run" \
  "A clean, pushed, ready-PR worker must record done — no false incomplete."

# --- the checker posts BOTH leads (issue #52) ------------------------------------
# An interrupted checker used to post NOTHING countable, so CHECKER_LIMIT stayed frozen
# at zero and the same PR was re-checked every cycle at a full CHECKER_BUDGET. Both
# cases below post on the PR number taken from the LOG basename (`demo-pr-9`), not the
# branch — a checker runs in the worker's `issue-N` worktree.
CHK_LOG="$LOGS/demo-pr-9.log"
CALLS="$LOGS/gh-calls.txt"

printf '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"Claude AI usage limit reached"}\n' >"$CHK_LOG"
: >"$CALLS"
cat >"$LED" <<LEDGER
- check pr#9 | owner/demo | issue-9 | $CHK_LOG | pid 4245 | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
GH_CALLS="$CALLS" FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready \
  finalize_dispatch "$CHK_LOG" "$LED" 4245 "$WT" checker >/dev/null 2>&1 || true
assert_contains "$(cat "$LED")" "status interrupted-ratelimit" \
  "a rate-limited checker records interrupted-ratelimit" \
  "classify_result must own the interrupted path for checkers too."
assert_contains "$(cat "$CALLS")" "pr comment 9 -R owner/demo" \
  "an interrupted checker comments on the PR from the log basename" \
  "The comment must land on the PR (demo-pr-9.log -> #9), not the worktree's issue branch."
assert_contains "$(cat "$CALLS")" "**Checker interrupted: interrupted-ratelimit**" \
  "an interrupted checker posts the '**Checker interrupted:' lead (issue #52)" \
  "Without this lead the round is uncountable and CHECKER_LIMIT never trips."
assert_contains "$(cat "$CALLS")" "CHECKER_LIMIT" \
  "the interrupted-checker comment names the cap it counts toward" \
  "Keep the escalation path legible in the comment, as the worker leads do."

# …and the incomplete lead still lands (the #40 behaviour this must not regress).
printf '{"type":"result","subtype":"success","is_error":false,"result":"executing in the background"}\n' >"$CHK_LOG"
rm -f "${CHK_LOG%.log}-verdict.json"
: >"$CALLS"
GH_CALLS="$CALLS" FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready \
  finalize_dispatch "$CHK_LOG" "$LED" 4245 "$WT" checker >/dev/null 2>&1 || true
assert_contains "$(cat "$CALLS")" "**Checker incomplete: incomplete-noverdict**" \
  "a checker that wrote no verdict still posts the '**Checker incomplete:' lead" \
  "Adding the interrupted lead must not displace the incomplete one (issue #40)."

# A checker that finished cleanly posts NOTHING — the false-positive guard.
printf '{"verdict":"pass"}\n' >"${CHK_LOG%.log}-verdict.json"
: >"$CALLS"
GH_CALLS="$CALLS" FAKE_TMUX_STATE=absent FAKE_GH_MODE=ready \
  finalize_dispatch "$CHK_LOG" "$LED" 4245 "$WT" checker >/dev/null 2>&1 || true
n_posts="$(grep -c 'pr comment' "$CALLS" 2>/dev/null || true)"
assert_eq "0" "$n_posts" \
  "a checker that wrote its verdict posts no incomplete/interrupted comment" \
  "Only a dispatch short of a clean finish may leave a countable round comment."
