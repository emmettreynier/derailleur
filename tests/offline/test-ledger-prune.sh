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
