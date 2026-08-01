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

# ── both no-clean-finish leads are capped, on SPLIT limits (issue #40) ─────────
# An exit-to-wait posts `**Worker incomplete:` where a cutoff posts
# `**Worker interrupted:`. Before #40 an incomplete round was invisible to
# WORKER_LIMIT, so a wedged tmux job re-dispatched every cycle forever with no path to
# needs-input. Both are counted now, but on separate caps (#40 amendment): only
# `incomplete-waiting` (a cheap babysit handoff — the retry reattaches and exits for
# cents) rides the loose WORKER_WAIT_LIMIT; every `**Worker interrupted:` and every
# other incomplete reason is a malfunction on the tight WORKER_LIMIT. A recording gh
# shim drives the comment history and captures the escalation calls.
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

# write_comments <body> [<body> ...] -> the gh shim's comment history, oldest first
write_comments() {
  { printf '{"comments":['
    local first=1 b
    for b in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"body":"%s"}' "$b"
    done
    printf ']}\n'
  } >"$GH_COMMENTS"
}
WAIT_C='**Worker incomplete: incomplete-waiting**. exited to wait.'
NOPR_C='**Worker incomplete: incomplete-nopr**. exited without a PR.'
CUT_C='**Worker interrupted: interrupted-budget**. cut off.'
write_repeated() {   # $1 = body, $2 = count -> that body repeated $2 times
  local i=0
  { printf '{"comments":['
    while [ "$i" -lt "$2" ]; do
      [ "$i" -eq 0 ] || printf ','
      printf '{"body":"%s"}' "$1"
      i=$((i + 1))
    done
    printf ']}\n'
  } >"$GH_COMMENTS"
}

# (a) the wait class rides the LOOSE limit: 10 trailing incomplete-waiting escalate…
write_repeated "$WAIT_C" 10
write_incomplete_ledger "$LED2"
out2="$(run_prune "$LED2")"
assert_contains "$out2" "⚠ was incomplete-waiting" \
  "an incomplete-* status is surfaced on prune like interrupted-*" \
  "The prune note must prefix-match incomplete as well as interrupted (bin/ledger-prune.sh)."
assert_contains "$out2" "WORKER_WAIT_LIMIT reached (10/10)" \
  "ten trailing incomplete-waiting attempts hit WORKER_WAIT_LIMIT" \
  "The wait class must still have a backstop — exempting it reopens the #40 hole."
assert_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "hitting WORKER_WAIT_LIMIT labels the issue needs-input" \
  "The escalation must actually apply the label, not just print."

# …and 9 do not (the loose limit really is 10, not 4 — legitimate multi-session
# progress on a long detached run must not be escalated as a malfunction).
write_repeated "$WAIT_C" 9
write_incomplete_ledger "$LED2"
out3="$(run_prune "$LED2")"
assert_not_contains "$out3" "reached (" \
  "nine trailing incomplete-waiting attempts do NOT escalate" \
  "WORKER_WAIT_LIMIT must default to 10, and waiting must not count against WORKER_LIMIT."
assert_not_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "no needs-input label below WORKER_WAIT_LIMIT" \
  "Escalation side effects must not fire before the limit."

# (b) every OTHER incomplete reason is a malfunction on the TIGHT limit: an exit with
# no PR is not a babysit handoff, so four of them escalate at WORKER_LIMIT.
write_repeated "$NOPR_C" 4
write_incomplete_ledger "$LED2"
out4="$(run_prune "$LED2")"
assert_contains "$out4" "WORKER_LIMIT reached (4/4)" \
  "four trailing incomplete-nopr attempts hit WORKER_LIMIT" \
  "Only incomplete-waiting rides the loose limit; other reasons stay on WORKER_LIMIT (#40 amendment)."

# (c) interrupted comments count in the same tight class as the non-wait incompletes.
write_comments "$CUT_C" "$NOPR_C" "$CUT_C" "$NOPR_C"
write_incomplete_ledger "$LED2"
out5="$(run_prune "$LED2")"
assert_contains "$out5" "WORKER_LIMIT reached (4/4)" \
  "interrupted and non-wait incomplete attempts share WORKER_LIMIT" \
  "A cutoff and a malfunctioning exit are the same class — one tight cap."

# (d) a MIXED trailing run tallies each class independently: 3 waiting + 3 nopr is
# under both limits, so it must not escalate (6 would have, under one shared cap).
write_comments "$WAIT_C" "$NOPR_C" "$WAIT_C" "$NOPR_C" "$WAIT_C" "$NOPR_C"
write_incomplete_ledger "$LED2"
out6="$(run_prune "$LED2")"
assert_not_contains "$out6" "reached (" \
  "a mixed run of 3 waiting + 3 nopr escalates neither class" \
  "The two classes must be tallied independently, each against its own limit."
assert_not_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "no needs-input label from a mixed sub-limit run" \
  "Independent tallies must not be summed into one count."

# (e) the per-generation reset still holds, for BOTH counters: any intervening comment
# zeroes them, so a progressing issue is never penalized for last round's stall.
write_comments "$WAIT_C" "$WAIT_C" "$WAIT_C" "$NOPR_C" "$NOPR_C" "$NOPR_C" "$NOPR_C" \
  "Pushed the reprojection fix — should be unblocked now."
write_incomplete_ledger "$LED2"
out7="$(run_prune "$LED2")"
assert_not_contains "$out7" "reached (" \
  "a human reply after the no-finish run resets both counters (no escalation)" \
  "Only TRAILING no-clean-finish comments count — a progressing issue must not be penalized."
assert_not_contains "$(cat "$GH_CALLS")" "--add-label needs-input" \
  "no needs-input label applied when the counts were reset" \
  "The reset must prevent the escalation side effects, not just the message."

# (f) both limits are env-overridable, exactly like each other.
write_repeated "$WAIT_C" 2
write_incomplete_ledger "$LED2"
: >"$GH_CALLS"
out8="$(PATH="$SHIM2:$PATH" LEDGER="$LED2" WORKER_WAIT_LIMIT=2 "$LP" 2>&1)"
assert_contains "$out8" "WORKER_WAIT_LIMIT reached (2/2)" \
  "WORKER_WAIT_LIMIT is env-overridable" \
  "The loose limit must read WORKER_WAIT_LIMIT from the environment (README documents it)."
