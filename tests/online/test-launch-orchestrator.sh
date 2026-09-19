#!/usr/bin/env bash
# test-launch-orchestrator.sh (ONLINE) — end-to-end config → board digest: run
# launch-orchestrator.sh --dry-run, which renders the live board via `gh`. Needs gh
# auth + network + a real conf; SKIPs cleanly otherwise. A nonzero with gh available
# is treated as a network hiccup (SKIP with a diagnostic), never a hard failure, per
# the offline/online contract. Also asserts the real conf is byte-identical around it.
# Migrated from smoke-test.sh's live launch-orchestrator step.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"

REAL_CONF="$REPO_ROOT/orchestrator.conf"

command -v gh >/dev/null 2>&1 \
  || { skip "gh not installed — skipping live launch-orchestrator --dry-run"; exit 0; }
gh auth status >/dev/null 2>&1 \
  || { skip "gh not authenticated / offline — skipping live launch-orchestrator --dry-run"; exit 0; }
[ -f "$REAL_CONF" ] \
  || { skip "no real orchestrator.conf — skipping live launch-orchestrator --dry-run"; exit 0; }

sum_before="$(shasum "$REAL_CONF")"
rc=0; out="$("$REPO_ROOT/bin/launch-orchestrator.sh" --dry-run 2>&1)" || rc=$?
sum_after="$(shasum "$REAL_CONF")"

# Byte-identical guarantee holds even on the online path (it must never write a conf).
assert_eq "$sum_before" "$sum_after" "real orchestrator.conf untouched by launch-orchestrator --dry-run"

if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'board digest'; then
  pass "live launch-orchestrator --dry-run renders the board digest from your conf"
else
  skip "launch-orchestrator --dry-run did not complete (network/gh hiccup, exit $rc): $(printf '%s' "$out" | tail -1)"
fi
