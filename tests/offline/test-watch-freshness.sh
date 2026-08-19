#!/usr/bin/env bash
# test-watch-freshness.sh (offline) — watch-dispatch.sh's dispatch-identity /
# freshness guard (issue #66). Everything runs against a throwaway sandbox ORCH: no
# network, no gh, nothing dispatched, nothing spent.
#
# The defect this covers: both of the watch's evidence sources outlive the dispatch
# that produced them, so a watch armed in the SAME TURN as `dr launch-*` (which the
# interactive brief mandates) reported the PREVIOUS dispatch's terminal state — a
# worker called finished while still running, and a superseded `changes_requested`
# reported and analysed at length when the real verdict was `pass`.
#
# Unlike test-watch-dispatch.sh (pure --dry-run classification), the race cases here
# need the watch LOOP and a deliberately delayed ledger append / verdict rotation, so
# this file does sleep — in 1s steps, a few seconds total.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
sandbox_copy_script "$SB" watch-dispatch
WATCH="$SB/bin/watch-dispatch.sh"
LG="$SB/ledger.md"
NOW="$(date -u '+%FT%TZ')"

# ledger_worker/ledger_checker <file> <num> <pid> <dispatched-ts> <status> — append one
# line in the exact shape the launchers write (`>>`: the real ledger is append-only).
ledger_worker()  { printf -- '- #%s | owner/demo | issue-%s | %s/logs/demo-issue-%s.log | pid %s | dispatched %s | status %s\n' \
                     "$2" "$2" "$SB" "$2" "$3" "$4" "$5" >>"$1"; }
ledger_checker() { printf -- '- check pr#%s | owner/demo | issue-9 | %s/logs/demo-pr-%s.log | pid %s | dispatched %s | status %s\n' \
                     "$2" "$SB" "$2" "$3" "$4" "$5" >>"$1"; }

# ── (b) previous terminal line only, this dispatch's not appended yet ─────────
# The observed Race 1: `dr launch-worker` has detached, the append is a beat behind,
# and the newest matching line is the last run's `incomplete-waiting`. It must NOT be
# read as this dispatch's state, and the wait must be BOUNDED and loud.
: >"$LG"; ledger_worker "$LG" 47 1 "2026-08-06T23:24:53Z" "incomplete-waiting"
rc=0; out="$("$WATCH" --interval 1 --arm-timeout 2 demo#47 2>&1)" || rc=$?
assert_rc 0 "$rc" "watch with only a PREVIOUS terminal line exits 0" \
  "The bounded arming wait must end cleanly, not error."
assert_not_contains "$out" "-> incomplete-waiting" \
  "a previous dispatch's terminal line is never reported as this dispatch's state (race 1)" \
  "resolve_line must reject a ledger line older than the watched dispatch (bin/watch-dispatch.sh, issue #66)."
assert_matches "$out" 'demo#47 \(worker\) -> no-dispatch-record' \
  "no line for this dispatch yet times out LOUDLY rather than resolving off the old one" \
  "An armed watch that never sees its own ledger line must report no-dispatch-record, not the previous run's status."
assert_matches "$out" 'pass @<pid> or --since' \
  "the timeout message names the corrective flags" \
  "The no-dispatch-record note must tell the operator how to watch an earlier dispatch on purpose."

# ── the grace window is closed by the arm-time snapshot ──────────────────────
# A previous dispatch that failed FAST and was re-dispatched immediately leaves a
# terminal line inside the derived floor's grace window, so the timestamp alone can't
# reject it. A line already terminal when the watch armed is the previous run's news
# whatever its timestamp says.
: >"$LG"; ledger_worker "$LG" 52 99999999 "$NOW" "interrupted-error"
rc=0; out="$("$WATCH" --interval 1 --arm-timeout 2 demo#52 2>&1)" || rc=$?
assert_rc 0 "$rc" "watch with a JUST-finished previous line exits 0"
assert_not_contains "$out" "-> interrupted-error" \
  "a terminal line inside the grace window is still not this dispatch's state" \
  "The arm-time staleness rule must suppress a line that was already terminal when the watch armed."
assert_not_contains "$out" "-> unknown" \
  "and it is not laundered into 'unknown' either" \
  "A stale line's dead pid must not be reported as this dispatch's crash (issue #66)."
assert_matches "$out" 'demo#52 \(worker\) -> no-dispatch-record' "it times out as no-dispatch-record"

# ── (a) previous terminal line + this dispatch's line -> the new one wins ─────
# `--since` is the operator asserting the identity by timestamp (the no-pid form the
# issue specifies): the line at/after it is this dispatch's, the one before it is not.
: >"$LG"
ledger_worker "$LG" 47 1 "2026-08-06T23:24:53Z" "incomplete-waiting"   # previous run
ledger_worker "$LG" 47 "$$" "$NOW" "interrupted-budget"                # this dispatch
rc=0; out="$("$WATCH" --dry-run --since "$NOW" demo#47 2>&1)" || rc=$?
assert_rc 0 "$rc" "snapshot with both lines present exits 0"
assert_matches "$out" 'demo#47 \(worker\) -> interrupted-budget' \
  "this dispatch's line wins over the previous one" \
  "The newest line at/after the floor is the watched dispatch's — see resolve_line."
assert_not_contains "$out" "incomplete-waiting" \
  "the previous line is not reported once this dispatch's line exists" \
  "Only one line per item may fire, and it must be the watched dispatch's."
# The floor is what does that work: with only a line from BEFORE it, there is no line
# for this dispatch — the item is arming, never resolved off the older run.
: >"$LG"; ledger_worker "$LG" 48 1 "2026-08-06T23:24:53Z" "incomplete-waiting"
rc=0; out="$("$WATCH" --dry-run --since "$NOW" demo#48 2>&1)" || rc=$?
assert_matches "$out" 'demo#48 \(worker\) -> arming' \
  "a line dispatched before the floor is not this dispatch's state" \
  "resolve_line must compare the line's 'dispatched' ts against the floor (issue #66)."
assert_not_contains "$out" "incomplete-waiting" \
  "and its status is not reported" \
  "A pre-floor line must produce no terminal value at all."

# ── the pid resolves the line BY IDENTITY, not by position ───────────────────
# Deliberately out of append order: with `@<pid>` supplied, position is irrelevant —
# only the line carrying that pid may be read as this dispatch's state.
: >"$LG"
ledger_worker "$LG" 61 "$$" "$NOW" "done"                              # this dispatch
ledger_worker "$LG" 61 1 "2026-08-06T23:24:53Z" "interrupted-ratelimit" # an older run, LAST in file
rc=0; out="$("$WATCH" --dry-run "demo#61@$$" 2>&1)" || rc=$?
assert_rc 0 "$rc" "pid-resolved snapshot exits 0"
assert_matches "$out" 'demo#61 \(worker\) -> done' \
  "the pid selects the watched dispatch's line regardless of file position" \
  "ledger_line must filter on the '| pid <pid> |' field when a pid is supplied (bin/watch-dispatch.sh)."
assert_not_contains "$out" "-> interrupted-ratelimit" \
  "a same-item line with a different pid is never read as this dispatch's" \
  "Pid resolution must ignore other dispatches of the same item."
assert_not_contains "$out" "demo#61@" \
  "the reported label drops the @pid suffix" \
  "The label is the item token; the pid is identity, not part of the name."

# ── (c) stale verdict + status dispatched -> NOT terminal ────────────────────
# The observed Race 2: #49 rotates the verdict at dispatch, but the rotation happens
# INSIDE the launcher, so a same-turn watch can poll the un-rotated file first. `mv`
# preserves mtime, which is what made the stale read invisible.
: >"$LG"; ledger_checker "$LG" 75 "$$" "$NOW" "dispatched"
printf '{"verdict":"changes_requested"}\n' >"$SB/logs/demo-pr-75-verdict.json"
touch -t 202608081412 "$SB/logs/demo-pr-75-verdict.json"
rc=0; out="$("$WATCH" --dry-run "demo#pr75@$$" 2>&1)" || rc=$?
assert_rc 0 "$rc" "stale-verdict snapshot exits 0"
assert_matches "$out" 'demo#pr75 \(checker\) -> pending' \
  "a verdict written BEFORE this dispatch started is not this dispatch's verdict" \
  "item_state must require verdict mtime >= the line's own 'dispatched' ts (issue #66)."
assert_not_contains "$out" "changes_requested" \
  "the superseded verdict is not reported at all" \
  "A stale verdict must fall through to the ledger status, not outrank it."

# ── (d) + addendum: a FRESH verdict is reported, but only once finalized ─────
# The sibling failure observed on derailleur PR #67: the verdict JSON landed and the
# watch reported `-> pass` and exited while the checker was still alive — `checked-pass`
# was not applied for another ~7 minutes. A written verdict is this dispatch's news but
# NOT a finish line: the comment/label/PR flip are still ahead of it.
: >"$LG"; ledger_checker "$LG" 76 "$$" "$NOW" "dispatched"
printf '{"verdict":"pass"}\n' >"$SB/logs/demo-pr-76-verdict.json"
rc=0; out="$("$WATCH" --dry-run "demo#pr76@$$" 2>&1)" || rc=$?
assert_rc 0 "$rc" "fresh-verdict-while-live snapshot exits 0"
assert_matches "$out" 'demo#pr76 \(checker\) -> pending \(verdict pass written; dispatch not finalized yet)' \
  "a fresh verdict + live pid + status dispatched is PENDING, and says why" \
  "A written verdict must not fire while the dispatch still has label/comment work pending (issue #66 addendum)."
assert_not_contains "$out" "-> pass" \
  "the verdict does not fire on its own" \
  "Only a terminal ledger status (or a dead pid) may end a checker watch."
# Same state, ledger now finalized: terminal, reporting the verdict (what changed is
# WHEN the watch fires, not what it says).
: >"$LG"; ledger_checker "$LG" 76 "$$" "$NOW" "done"
rc=0; out="$("$WATCH" --dry-run "demo#pr76@$$" 2>&1)" || rc=$?
assert_matches "$out" 'demo#pr76 \(checker\) -> pass' \
  "once the ledger flips to done the fresh verdict IS the reported outcome" \
  "The verdict stays what gets reported once terminal — see item_state's 'done' branch."

# ── (e) dead pid + status dispatched -> unknown (never waited out) ───────────
: >"$LG"; ledger_worker "$LG" 77 99999999 "$NOW" "dispatched"
rc=0; out="$("$WATCH" --dry-run "demo#77@99999999" 2>&1)" || rc=$?
assert_matches "$out" 'demo#77 \(worker\) -> unknown' \
  "a dead pid whose status was never finalized is still reported 'unknown'" \
  "The freshness guard must not become a way to wait out a crash (issue #66)."
# ...including a checker that wrote its verdict and then died before publishing it:
# the verdict is real, so name it rather than letting a bare `unknown` imply nothing ran.
: >"$LG"; ledger_checker "$LG" 78 99999999 "$NOW" "dispatched"
printf '{"verdict":"pass_with_findings"}\n' >"$SB/logs/demo-pr-78-verdict.json"
rc=0; out="$("$WATCH" --dry-run "demo#pr78@99999999" 2>&1)" || rc=$?
assert_matches "$out" 'demo#pr78 \(checker\) -> unknown \(verdict pass_with_findings written, but the dispatch never finalized' \
  "a crashed checker with a fresh verdict is reported, not waited out" \
  "A dead pid must fire even with a fresh verdict on disk, and should name it."

# ── same-turn arming is race-free (the shape the brief mandates) ─────────────
# Stub the launcher's real ordering: it returns as soon as it has detached, and the
# ledger append + verdict rotation land a beat later. The watch is armed in the SAME
# turn, with the pid the launcher printed. It must ride out the whole sequence and fire
# exactly once, on this dispatch's verdict.
: >"$LG"; ledger_checker "$LG" 80 1 "2026-08-08T14:00:00Z" "done"        # previous round
printf '{"verdict":"changes_requested"}\n' >"$SB/logs/demo-pr-80-verdict.json"
touch -t 202608081412 "$SB/logs/demo-pr-80-verdict.json"
sleep 20 & FAKE_PID=$!            # stands in for the live detached dispatch
(
  sleep 1
  mv -f "$SB/logs/demo-pr-80-verdict.json" "$SB/logs/demo-pr-80-verdict.prev.json"  # #49 rotation
  # One dispatch ts, reused on the status flip: finalize_dispatch edits `status` in
  # place and never rewrites the timestamp, so the real line's ts stays the launch's.
  dts="$(date -u '+%FT%TZ')"
  ledger_checker "$LG" 80 "$FAKE_PID" "$dts" "dispatched"
  sleep 1
  printf '{"verdict":"pass"}\n' >"$SB/logs/demo-pr-80-verdict.json"
  sleep 1
  : >"$LG"
  ledger_checker "$LG" 80 1 "2026-08-08T14:00:00Z" "done"
  ledger_checker "$LG" 80 "$FAKE_PID" "$dts" "done"
) >/dev/null 2>&1 &
STUB_PID=$!
rc=0; out="$("$WATCH" --interval 1 --arm-timeout 30 "demo#pr80@$FAKE_PID" 2>&1)" || rc=$?
wait "$STUB_PID" 2>/dev/null || true
# Reap the stand-in pid quietly: `kill` alone leaves the shell to announce
# "Terminated: 15 sleep" on some later line, which reads like a test error.
{ kill "$FAKE_PID" && wait "$FAKE_PID"; } 2>/dev/null || true
assert_rc 0 "$rc" "a watch armed in the same turn as a (stubbed) launch exits 0"
assert_matches "$out" 'demo#pr80 \(checker\) -> pass' \
  "same-turn arming reports THIS dispatch's verdict" \
  "With the ledger append and verdict rotation delayed, the watch must wait for its own dispatch's news (issue #66)."
assert_not_contains "$out" "changes_requested" \
  "and never the previous round's, at any point in the sequence" \
  "This is the exact false report observed on california-pesticides PR #75."
assert_not_contains "$out" "no-dispatch-record" \
  "the bounded arming wait does not trip while the append is merely late" \
  "--arm-timeout must be generous enough to cover a launcher that is still detaching."
assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'demo#pr80 (checker) ->')" \
  "the item fires exactly once" \
  "An item must be reported once, on its own terminal state."

# ── the same, with NO pid supplied (floor + arm-time snapshot only) ──────────
: >"$LG"; ledger_worker "$LG" 90 99999999 "2026-08-06T23:24:53Z" "incomplete-waiting"
sleep 20 & FAKE_PID2=$!
(
  sleep 1
  dts2="$(date -u '+%FT%TZ')"
  ledger_worker "$LG" 90 "$FAKE_PID2" "$dts2" "dispatched"
  sleep 2
  : >"$LG"
  ledger_worker "$LG" 90 99999999 "2026-08-06T23:24:53Z" "incomplete-waiting"
  ledger_worker "$LG" 90 "$FAKE_PID2" "$dts2" "done"
) >/dev/null 2>&1 &
STUB_PID2=$!
rc=0; out="$("$WATCH" --interval 1 --arm-timeout 30 demo#90 2>&1)" || rc=$?
wait "$STUB_PID2" 2>/dev/null || true
{ kill "$FAKE_PID2" && wait "$FAKE_PID2"; } 2>/dev/null || true
assert_rc 0 "$rc" "same-turn arming with no pid exits 0"
assert_matches "$out" 'demo#90 \(worker\) -> done' \
  "with no pid, the derived floor + arm-time snapshot still wait for this dispatch" \
  "The no-identity path must be race-free too: the brief's operator may omit the pid."
assert_not_contains "$out" "-> incomplete-waiting" \
  "the previous dispatch's status never fires on the no-pid path" \
  "resolve_line's floor and arm-time snapshot must both be active when no identity is supplied."

# ── flag validation ─────────────────────────────────────────────────────────
rc=0; "$WATCH" --dry-run "demo#47@abc" >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "a non-numeric @pid exits 2" \
  "Item parsing must reject a malformed pid suffix."
rc=0; "$WATCH" --dry-run --since "not-a-time" demo#47 >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "an unparseable --since exits 2" \
  "--since must be ISO8601 or epoch seconds, and fail loud otherwise."
rc=0; out="$("$WATCH" --dry-run --since "$NOW" demo#47 2>&1)" || rc=$?
assert_rc 0 "$rc" "an ISO8601 --since is accepted" \
  "to_epoch must parse the launchers' own 'date -u +%FT%TZ' format."
