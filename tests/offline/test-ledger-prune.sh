#!/usr/bin/env bash
# test-ledger-prune.sh (offline) — ledger-prune.sh dead-pid pruning. A fixture entry
# with a dead pid is pruned; a live-pid ($$) entry is kept. A no-op `gh` shim on PATH
# isolates the LOCAL pid path (every gh lookup returns "unknown → keep"), so the test
# is hermetic + fast and exercises only pid liveness. New offline coverage (issue #31).
# (Real-gh closed-issue/merged-PR pruning lives in the online tier.)
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" ledger-prune
LP="$SB/bin/ledger-prune.sh"

SHIM="$(fake_gh_on_path "$(sandbox_tmp)")"   # gh → exit 0, empty stdout ⇒ state unknown ⇒ keep

# Fixture ledger: a dead-pid worker (must be pruned) + a live-pid worker (must be kept).
# status=dispatched (not "interrupted") so no gh-driven escalation path is taken.
LED="$SB/ledger-fixture.md"
cat >"$LED" <<LEDGER
- #10 | owner/demo | issue-10 | $SB/logs/demo-issue-10.log | pid 99999999 | dispatched 2026-01-01T00:00:00Z | status dispatched
- #40 | owner/demo | issue-40 | $SB/logs/demo-issue-40.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER

rc=0; out="$(PATH="$SHIM:$PATH" LEDGER="$LED" "$LP" 2>&1)" || rc=$?
assert_rc 0 "$rc" "ledger-prune exits 0 on the fixture"
assert_contains "$out" "kept 1 live, pruned 1" "one live kept, one dead-pid pruned" \
  "pid-liveness pruning is broken in bin/ledger-prune.sh."
assert_contains "$out" "pid 99999999 dead" "the pruned entry is surfaced as pid-dead" \
  "The pruned-entry stderr note should name the dead pid."

# The rewritten ledger keeps the live entry and drops the dead one.
kept="$(cat "$LED")"
assert_contains "$kept" "issue-40" "live-pid entry retained in the rewritten ledger"
assert_not_contains "$kept" "issue-10" "dead-pid entry removed from the rewritten ledger"

# ── WORKER_LIMIT counts BOTH no-clean-finish leads (issue #40) ─────────────────
# An exit-to-wait posts `**Worker incomplete:` where a cutoff posts
# `**Worker interrupted:`. They share ONE cap: before this, an incomplete round was
# invisible to WORKER_LIMIT, so a wedged tmux job re-dispatched every cycle forever
# with no path to needs-input. A recording gh shim drives the comment history and
# captures the escalation calls.
SHIM2="$(sandbox_tmp)"
export GH_CALLS="$SHIM2/gh-calls.txt"
export GH_COMMENTS="$SHIM2/comments.json"
: >"$GH_CALLS"
cat >"$SHIM2/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  case " $* " in
    *" --json state "*)    echo '{"state":"OPEN"}' ;;
    *" --json labels "*)   echo '{"labels":[]}' ;;
    *" --json comments "*) cat "$GH_COMMENTS" ;;
    *)                     echo '{}' ;;
  esac
fi
exit 0
SH
chmod +x "$SHIM2/gh"

# A dead pid makes the entry prunable (so the status surfacing runs at all); the
# status is `incomplete-*`, which must now take the same escalation path as interrupted.
write_incomplete_ledger() {   # $1 = destination ledger path
  cat >"$1" <<LEDGER
- #77 | owner/demo | issue-77 | $SB/logs/demo-issue-77.log | pid 99999999 | dispatched 2026-01-01T00:00:00Z | status incomplete-waiting
LEDGER
}
run_prune() {   # $1 = ledger path -> prune output (stdout+stderr)
  : >"$GH_CALLS"
  PATH="$SHIM2:$PATH" LEDGER="$1" "$LP" 2>&1
}

LED2="$SB/ledger-incomplete.md"

# (a) four trailing `**Worker incomplete:` comments hit WORKER_LIMIT.
cat >"$GH_COMMENTS" <<'JSON'
{"comments":[
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"**Worker incomplete: incomplete-draft**. exited to wait."},
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."}
]}
JSON
write_incomplete_ledger "$LED2"
out2="$(run_prune "$LED2")"
assert_contains "$out2" "⚠ was incomplete-waiting" \
  "an incomplete-* status is surfaced on prune like interrupted-*" \
  "The prune note must prefix-match incomplete as well as interrupted (bin/ledger-prune.sh)."
assert_contains "$out2" "WORKER_LIMIT reached (4/4)" \
  "four trailing **Worker incomplete: comments hit WORKER_LIMIT" \
  "trailing_interrupted_count must count the incomplete lead too (issue #40)."
assert_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "hitting WORKER_LIMIT labels the issue needs-input" \
  "The escalation must actually apply the label, not just print."

# (b) the two leads share ONE cap: a mixed run of interrupted + incomplete escalates.
cat >"$GH_COMMENTS" <<'JSON'
{"comments":[
 {"body":"**Worker interrupted: interrupted-budget**. cut off."},
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"**Worker interrupted: interrupted-ratelimit**. cut off."},
 {"body":"**Worker incomplete: incomplete-nopr**. exited to wait."}
]}
JSON
write_incomplete_ledger "$LED2"
out3="$(run_prune "$LED2")"
assert_contains "$out3" "WORKER_LIMIT reached (4/4)" \
  "interrupted and incomplete attempts count against the SAME WORKER_LIMIT" \
  "Both leads are 'an attempt with no clean finish' — one shared cap, per issue #40."

# (c) the per-generation reset still holds: any intervening comment zeroes the count.
cat >"$GH_COMMENTS" <<'JSON'
{"comments":[
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"**Worker incomplete: incomplete-waiting**. exited to wait."},
 {"body":"Pushed the reprojection fix — should be unblocked now."}
]}
JSON
write_incomplete_ledger "$LED2"
out4="$(run_prune "$LED2")"
assert_not_contains "$out4" "WORKER_LIMIT reached" \
  "a human reply after the incomplete run resets the count (no escalation)" \
  "Only TRAILING no-clean-finish comments count — a progressing issue must not be penalized."
assert_not_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "no needs-input label applied when the count was reset" \
  "The reset must prevent the escalation side effects, not just the message."
