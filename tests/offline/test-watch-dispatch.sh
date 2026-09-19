#!/usr/bin/env bash
# test-watch-dispatch.sh (offline) — watch-dispatch.sh terminal-state classification
# against a throwaway ledger/verdict fixture, plus malformed/no-arg rejection.
# Migrated from smoke-test.sh check (e). Pure local-signal logic: no loop, no sleep,
# no network — nothing dispatched, nothing spent.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/watch-dispatch.sh" "bin/watch-dispatch.sh present" \
  "The watch script is missing from bin/."

# Sandbox ORCH so watch-dispatch's `cd dirname/..` root resolution lands in scratch.
SB="$(new_sandbox)"
sandbox_copy_script "$SB" watch-dispatch
WATCH="$SB/bin/watch-dispatch.sh"

# Fixtures ($$ = this live shell): a done worker (status flip); a checker still
# 'dispatched' but WITH a written verdict (=> PENDING — a written verdict is this
# dispatch's news but not a finish line, since the comment/label/PR flip are still
# ahead of it; issue #66 addendum, and see tests/offline/test-watch-freshness.sh); a
# FINALIZED checker whose verdict is what gets reported; a worker whose pid is dead
# while status never finalized (=> unknown); and a genuinely live dispatched worker
# (=> pending, must NOT be terminal).
#
# Plus (issue #40) an `incomplete-waiting` worker — terminal, but the work isn't
# finished, so it must carry the re-dispatch hint — and an `incomplete-noverdict`
# checker WITH a stale verdict file on disk, where the ledger status must win (it is
# written after the session exited, so it is the later and more authoritative word).
#
# Plus (issue #40 amendment) three `incomplete-waiting` CHECKERS, which is the case
# where status-wins would otherwise throw away real information: with a parseable
# verdict on disk both facts must be reported (verdict written AND session alive);
# with the verdict missing or unparseable the plain hint stands, quietly.
cat >"$SB/ledger.md" <<LEDGER
- #10 | owner/demo | issue-10 | $SB/logs/demo-issue-10.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status done
- check pr#20 | owner/demo | issue-10 | $SB/logs/demo-pr-20.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
- check pr#21 | owner/demo | issue-10 | $SB/logs/demo-pr-21.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status done
- #30 | owner/demo | issue-30 | $SB/logs/demo-issue-30.log | pid 99999999 | dispatched 2026-01-01T00:00:00Z | status dispatched
- #40 | owner/demo | issue-40 | $SB/logs/demo-issue-40.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
- #50 | owner/demo | issue-50 | $SB/logs/demo-issue-50.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status incomplete-waiting
- check pr#60 | owner/demo | issue-50 | $SB/logs/demo-pr-60.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status incomplete-noverdict
- check pr#70 | owner/demo | issue-50 | $SB/logs/demo-pr-70.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status incomplete-waiting
- check pr#80 | owner/demo | issue-50 | $SB/logs/demo-pr-80.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status incomplete-waiting
- check pr#90 | owner/demo | issue-50 | $SB/logs/demo-pr-90.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status incomplete-waiting
LEDGER
printf '{"verdict":"checked-pass"}\n'       >"$SB/logs/demo-pr-20-verdict.json"
printf '{"verdict":"checked-pass"}\n'       >"$SB/logs/demo-pr-21-verdict.json"
printf '{"verdict":"pass"}\n'               >"$SB/logs/demo-pr-60-verdict.json"
printf '{"verdict":"pass_with_findings"}\n' >"$SB/logs/demo-pr-70-verdict.json"
# pr#80: no verdict file at all.  pr#90: a truncated/unparseable one.
printf '{"verdict": "pass' >"$SB/logs/demo-pr-90-verdict.json"

rc=0
wd_out="$("$WATCH" --dry-run demo#10 demo#pr20 demo#pr21 demo#30 demo#40 demo#50 demo#pr60 \
            demo#pr70 demo#pr80 demo#pr90 2>&1)" || rc=$?
assert_rc 0 "$rc" "watch-dispatch --dry-run exits 0 on a valid fixture" \
  "The script should classify each item and exit 0 in --dry-run; see bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#10 \(worker\) -> done' "status=done worker classified 'done'" \
  "Ledger status-flip detection is broken in bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#pr20 \(checker\) -> pending \(verdict checked-pass written; dispatch not finalized yet)' \
  "a written verdict on a still-dispatched checker is PENDING, and names the verdict" \
  "A verdict file is not a finish line: the label/comment/PR flip are still ahead of it (issue #66 addendum)."
assert_matches "$wd_out" 'demo#pr21 \(checker\) -> checked-pass' \
  "a FINALIZED checker reports its verdict as the outcome" \
  "Verdict-file detection (jq .verdict) is broken, or a terminal status did not report the verdict."
assert_matches "$wd_out" 'demo#30 \(worker\) -> unknown' "dead-but-unfinalized pid classified 'unknown'" \
  "The silence-is-not-success guard (pid liveness) is broken in bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#40 \(worker\) -> pending' "live, still-dispatched worker classified 'pending'" \
  "A running dispatch must NOT be classified terminal — check the status/pid logic."
assert_matches "$wd_out" 'demo#50 \(worker\) -> incomplete-waiting \(re-dispatch required\)' \
  "incomplete-waiting worker is terminal AND carries the re-dispatch hint" \
  "incomplete-* means the dispatch ended without finalizing — terminal_note must flag it (issue #40)."
assert_matches "$wd_out" 'demo#pr60 \(checker\) -> incomplete-noverdict \(re-dispatch required\)' \
  "incomplete-noverdict checker wins over a stale verdict file on disk" \
  "The ledger status is written after the session exits, so incomplete-* outranks the verdict file."
assert_not_contains "$wd_out" "demo#pr60 (checker) -> pass" \
  "the stale verdict file does not mask the checker's incomplete status" \
  "item_state must consult the status before the verdict file when the status is incomplete-*."
assert_not_contains "$wd_out" "demo#10 (worker) -> done (re-dispatch required)" \
  "a plain 'done' carries no re-dispatch hint" \
  "terminal_note must fire only for incomplete-* — see bin/watch-dispatch.sh."

# ── verdict passthrough on incomplete-waiting (issue #40 amendment) ────────────
# Status still wins (the live session is the more urgent fact for anyone deciding
# whether to dispatch into that worktree), but a verdict already on disk is real news
# and must be reported alongside it rather than discarded.
assert_matches "$wd_out" \
  'demo#pr70 \(checker\) -> incomplete-waiting \(verdict pass_with_findings already written; tmux session alive — reconcile before dispatching into that worktree\)' \
  "incomplete-waiting checker with a written verdict reports BOTH facts" \
  "terminal_note must name the verdict and the live session for an incomplete-waiting checker (issue #40 amendment)."
assert_matches "$wd_out" 'demo#pr80 \(checker\) -> incomplete-waiting \(re-dispatch required\)' \
  "incomplete-waiting checker with no verdict file keeps the plain hint" \
  "A missing verdict file must fall through to the plain hint, not error."
assert_matches "$wd_out" 'demo#pr90 \(checker\) -> incomplete-waiting \(re-dispatch required\)' \
  "incomplete-waiting checker with an unparseable verdict keeps the plain hint" \
  "jq failure on the verdict file must be swallowed — no error output, no nonzero exit."
assert_not_contains "$wd_out" "parse error" \
  "an unparseable verdict file produces no error output" \
  "jq's stderr must be suppressed in terminal_note (bin/watch-dispatch.sh)."
# The worker hint is unchanged: the passthrough is checker-only, so a worker item never
# grows a verdict clause even when a same-numbered verdict file exists.
printf '{"verdict":"pass"}\n' >"$SB/logs/demo-pr-50-verdict.json"
rc=0; w50="$("$WATCH" --dry-run demo#50 2>&1)" || rc=$?
assert_rc 0 "$rc" "worker-only snapshot exits 0"
assert_matches "$w50" 'demo#50 \(worker\) -> incomplete-waiting \(re-dispatch required\)' \
  "an incomplete-waiting WORKER keeps its hint verbatim" \
  "The verdict passthrough is checker-only — worker items must be untouched."

# malformed item + no-args each exit 2
rc=0; "$WATCH" --dry-run bogusitem >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "malformed item token exits 2" \
  "Item parsing must reject anything not <slug>#<issue> / <slug>#pr<n>."
rc=0; "$WATCH" >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "no-args exits 2" \
  "The script must require at least one item to watch."
