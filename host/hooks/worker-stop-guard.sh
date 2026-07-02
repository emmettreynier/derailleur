#!/usr/bin/env bash
# worker-stop-guard.sh — Stop hook: refuse to let a worker session end until it has
# left a trail. Enforces the worker-brief exit contract mechanically (a brief is a
# suggestion; a hook is enforcement). See design.md — Phase 3.
#
# A worker has exactly two legitimate ways to finish:
#   1. shipped/working → a PR exists for its branch (draft or ready), or
#   2. blocked         → it added the "needs-input" label (paired with a comment).
# Anything else (code written, no PR, no escalation) is invisible to the rest of the
# loop — the digest and checker route on PR state — so we block the stop and nudge.
#
# Wired in by launch-worker.sh via --settings as: worker-stop-guard.sh <ISSUE> <REPO>
# (workers only; checkers have a different contract and are untouched).
#
# Contract: a Stop hook reads the hook payload as JSON on stdin and may print
# {"decision":"block","reason":...} to force the agent to continue; the reason is
# fed back to the model. Exit 0 + no decision allows the stop.
set -euo pipefail

ISSUE="${1:?worker-stop-guard: missing <issue#> arg}"
REPO="${2:?worker-stop-guard: missing <repo> arg}"

payload="$(cat)"
cwd="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || true)"
stop_active="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("stop_hook_active", False)).lower())' 2>/dev/null || echo false)"

# One firm nudge: if we already blocked once this turn, allow the stop. This is the
# documented guard against Stop-hook infinite loops; the happy path (worker forgot,
# gets told, opens the PR, stops again) needs exactly one block. A worker that
# ignores the nudge is caught downstream (no PR shows in the digest) — not trapped
# here burning budget.
if [ "$stop_active" = "true" ]; then
  exit 0
fi

allow() { exit 0; }
block() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
PY
  exit 0
}

# A PR for this worker's branch satisfies the "shipped/working" exit.
branch=""
[ -n "$cwd" ] && branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
if [ -n "$branch" ]; then
  pr_count="$(gh pr list --repo "$REPO" --head "$branch" --state all --json number --jq 'length' 2>/dev/null || echo 0)"
  [ "${pr_count:-0}" -gt 0 ] && allow
fi

# The "needs-input" label satisfies the "blocked / escalated" exit.
if gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null \
     | grep -qx 'needs-input'; then
  allow
fi

block "You haven't left a trail, so this work would be invisible to the rest of the loop. Before finishing, do ONE of: (a) open a PR for this branch referencing \"Closes #$ISSUE\" with the results-summary section filled, or (b) if you're blocked on a research/judgment call, comment the specific question on #$ISSUE and add the \"needs-input\" label. Then you may stop."
