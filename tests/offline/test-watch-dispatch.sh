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
# 'dispatched' but WITH a written verdict (verdict must win over status); a worker
# whose pid is dead while status never finalized (=> unknown); and a genuinely live
# dispatched worker (=> pending, must NOT be terminal).
cat >"$SB/ledger.md" <<LEDGER
- #10 | owner/demo | issue-10 | $SB/logs/demo-issue-10.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status done
- check pr#20 | owner/demo | issue-10 | $SB/logs/demo-pr-20.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
- #30 | owner/demo | issue-30 | $SB/logs/demo-issue-30.log | pid 99999999 | dispatched 2026-01-01T00:00:00Z | status dispatched
- #40 | owner/demo | issue-40 | $SB/logs/demo-issue-40.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
printf '{"verdict":"checked-pass"}\n' >"$SB/logs/demo-pr-20-verdict.json"

rc=0
wd_out="$("$WATCH" --dry-run demo#10 demo#pr20 demo#30 demo#40 2>&1)" || rc=$?
assert_rc 0 "$rc" "watch-dispatch --dry-run exits 0 on a valid fixture" \
  "The script should classify each item and exit 0 in --dry-run; see bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#10 \(worker\) -> done' "status=done worker classified 'done'" \
  "Ledger status-flip detection is broken in bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#pr20 \(checker\) -> checked-pass' "checker verdict JSON wins over still-dispatched status" \
  "Verdict-file detection (jq .verdict) is broken, or it lost to the still-dispatched status."
assert_matches "$wd_out" 'demo#30 \(worker\) -> unknown' "dead-but-unfinalized pid classified 'unknown'" \
  "The silence-is-not-success guard (pid liveness) is broken in bin/watch-dispatch.sh."
assert_matches "$wd_out" 'demo#40 \(worker\) -> pending' "live, still-dispatched worker classified 'pending'" \
  "A running dispatch must NOT be classified terminal — check the status/pid logic."

# malformed item + no-args each exit 2
rc=0; "$WATCH" --dry-run bogusitem >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "malformed item token exits 2" \
  "Item parsing must reject anything not <slug>#<issue> / <slug>#pr<n>."
rc=0; "$WATCH" >/dev/null 2>&1 || rc=$?
assert_rc 2 "$rc" "no-args exits 2" \
  "The script must require at least one item to watch."
