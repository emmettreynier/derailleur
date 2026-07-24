#!/usr/bin/env bash
# test-ledger-prune-gh.sh (ONLINE) — ledger-prune.sh closed-issue pruning against
# real `gh`: a ledger entry for a genuinely CLOSED issue is pruned; one for an OPEN
# issue is kept. The issue numbers are derived at runtime from the current repo
# (`gh issue list`), so the test is repo-agnostic, not hardcoded. pid is "-" so only
# gh issue-state drives the decision. Needs gh auth + a real conf; SKIPs cleanly
# otherwise (and on any missing precondition). Read-only on GitHub — pruning only
# rewrites the throwaway fixture ledger. New online coverage (issue #31).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

REAL_CONF="$REPO_ROOT/orchestrator.conf"

command -v gh >/dev/null 2>&1 \
  || { skip "gh not installed — skipping ledger-prune real-gh pruning"; exit 0; }
gh auth status >/dev/null 2>&1 \
  || { skip "gh not authenticated / offline — skipping ledger-prune real-gh pruning"; exit 0; }
[ -f "$REAL_CONF" ] \
  || { skip "no real orchestrator.conf — skipping ledger-prune real-gh pruning"; exit 0; }

# Derive the current repo + one closed + one open issue at runtime.
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || { skip "could not resolve current repo via gh — skipping"; exit 0; }
CLOSED_NUM="$(gh issue list -R "$REPO" --state closed -L 1 --json number -q '.[0].number' 2>/dev/null || true)"
OPEN_NUM="$(gh issue list -R "$REPO" --state open -L 1 --json number -q '.[0].number' 2>/dev/null || true)"
{ [ -n "$CLOSED_NUM" ] && [ -n "$OPEN_NUM" ]; } \
  || { skip "repo $REPO lacks both a closed and an open issue to fixture — skipping"; exit 0; }

SB="$(new_sandbox)"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" ledger-prune
cp "$REAL_CONF" "$SB/orchestrator.conf"   # real identity so the guard passes (gitignored source)
LP="$SB/bin/ledger-prune.sh"

# pid "-" ⇒ pid liveness is skipped; only issue-state drives pruning.
LED="$SB/ledger-fixture.md"
cat >"$LED" <<LEDGER
- #$CLOSED_NUM | $REPO | issue-$CLOSED_NUM | $SB/logs/c.log | pid - | dispatched 2026-01-01T00:00:00Z | status dispatched
- #$OPEN_NUM | $REPO | issue-$OPEN_NUM | $SB/logs/o.log | pid - | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER

rc=0; out="$(LEDGER="$LED" "$LP" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  skip "ledger-prune did not complete against $REPO (network/gh hiccup, exit $rc): $(printf '%s' "$out" | tail -1)"
  exit 0
fi

kept="$(cat "$LED")"
assert_not_contains "$kept" "#$CLOSED_NUM |" "closed issue #$CLOSED_NUM pruned via real gh state" \
  "issue_closed()-driven pruning is broken in bin/ledger-prune.sh."
assert_contains "$kept" "#$OPEN_NUM |" "open issue #$OPEN_NUM kept (still actionable)" \
  "An open issue must never be pruned by ledger-prune.sh."
