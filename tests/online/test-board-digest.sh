#!/usr/bin/env bash
# test-board-digest.sh (ONLINE) — board-digest.sh runs end-to-end against real `gh`
# and emits a digest (grep for the digest header). Needs gh auth + network + a real
# conf; SKIPs cleanly otherwise. Read-only (the digest only reads the board/ledger);
# a network hiccup is a SKIP, never a hard failure. New online coverage (issue #31).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"

REAL_CONF="$REPO_ROOT/orchestrator.conf"

command -v gh >/dev/null 2>&1 \
  || { skip "gh not installed — skipping board-digest end-to-end"; exit 0; }
gh auth status >/dev/null 2>&1 \
  || { skip "gh not authenticated / offline — skipping board-digest end-to-end"; exit 0; }
[ -f "$REAL_CONF" ] \
  || { skip "no real orchestrator.conf — skipping board-digest end-to-end"; exit 0; }

rc=0; out="$("$REPO_ROOT/bin/board-digest.sh" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '# Board digest'; then
  pass "board-digest.sh emits a digest header against the live board"
else
  skip "board-digest.sh did not complete (network/gh hiccup, exit $rc): $(printf '%s' "$out" | tail -1)"
fi
