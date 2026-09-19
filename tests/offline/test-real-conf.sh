#!/usr/bin/env bash
# test-real-conf.sh (offline) — if a real orchestrator.conf is present, prove the
# OPERATOR'S actual identity passes the guard (not just temp fixtures), and that a run
# leaves it byte-identical. Deterministic + read-only (sourcing only reads the file);
# SKIPs cleanly when no real conf exists (e.g. CI, a fresh checkout). Migrated from
# smoke-test.sh's real-conf + byte-identical checks.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"

REAL_CONF="$REPO_ROOT/orchestrator.conf"
CONFIG_COMMON="$REPO_ROOT/bin/config-common.sh"

if [ ! -f "$REAL_CONF" ]; then
  skip "no real orchestrator.conf — copy orchestrator.conf.example and fill it (README Install step 5)"
  exit 0
fi

sum_before="$(shasum "$REAL_CONF")"

rc=0
out="$(
  (
    ORCH="$REPO_ROOT" ORCH_DIR="$REPO_ROOT"
    unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
    . "$CONFIG_COMMON"
  ) 2>&1
)" || rc=$?
assert_rc 0 "$rc" "real orchestrator.conf passes the guard (all identity fields filled)" \
  "Fill every field in orchestrator.conf (see README Install step 5), then re-run."

sum_after="$(shasum "$REAL_CONF")"
assert_eq "$sum_before" "$sum_after" "real orchestrator.conf untouched (byte-identical shasum before/after)" \
  "The suite must never write a real conf — this is a bug in a test."
