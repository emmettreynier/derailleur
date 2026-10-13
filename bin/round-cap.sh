#!/usr/bin/env bash
# round-cap.sh — would the NEXT worker / checker dispatch on this item exceed a round cap?
#
# The interactive path's enforcement of the cycle's round caps (issue #91). The
# autonomous loop enforces them in its own scripts — CHECKER_LIMIT in
# orchestrator-cycle.sh, WORKER_LIMIT / WORKER_WAIT_LIMIT in ledger-prune.sh — but
# neither launcher checks a cap, so an auto-chaining `/orchestrate` that only called the
# launchers would ping-pong worker <-> checker without bound. Before every FOLLOW-UP
# dispatch the interactive orchestrator runs this instead of tallying rounds in its own
# context.
#
# Same limits, same counters, separate enforcement:
#   checker  `gh pr view <pr> --json comments` | checker_rounds_this_generation
#            refused when rounds >= CHECKER_LIMIT          (exactly orchestrator-cycle.sh)
#   worker   `gh issue view <n> --json comments` | worker_no_finish_counts
#            refused when hard >= WORKER_LIMIT, or wait >= WORKER_WAIT_LIMIT
#                                                          (exactly ledger-prune.sh)
# Both counters live in bin/dispatch-common.sh and are reused, not reimplemented.
#
# READ-ONLY, by design: it never writes a label or a comment. The cycle escalates a
# tripped cap to `needs-input` because nobody is watching; here the operator IS present,
# so the caller stops and asks them instead. Unlike the cycle's fail-soft count (a flaky
# `gh` there reads as 0 so it never escalates in error), a `gh` failure or unparseable
# reply here is reported as `unknown` with its own exit code: the safe reading of "could
# not count" for an auto-chain is "stop and ask", which costs the operator one question.
#
# Usage:
#   round-cap.sh worker  <slug> <issue#>
#   round-cap.sh checker <slug> <pr#>
#
# Exit: 0 allow · 3 refuse (cap would be exceeded) · 1 unknown (could not count) · 2 usage
# Env:  CHECKER_LIMIT (4) · WORKER_LIMIT (4) · WORKER_WAIT_LIMIT (10) — the cycle's defaults
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=dispatch-common.sh
source "$ORCH/bin/dispatch-common.sh"

CHECKER_LIMIT="${CHECKER_LIMIT:-4}"
WORKER_LIMIT="${WORKER_LIMIT:-4}"
WORKER_WAIT_LIMIT="${WORKER_WAIT_LIMIT:-10}"

usage() {
  echo "usage: round-cap.sh worker <slug> <issue#> | round-cap.sh checker <slug> <pr#>" >&2
  exit 2
}
[ $# -eq 3 ] || usage
KIND="$1" SLUG="$2" NUM="$3"
case "$KIND" in worker|checker) : ;; *) usage ;; esac
case "$NUM" in ''|*[!0-9]*) usage ;; esac

unknown() { echo "round-cap: unknown — $KIND $SLUG ${NUM}: $* — stop and ask the operator"; exit 1; }

MANIFEST="$ORCH/projects/$SLUG.yml"
[ -f "$MANIFEST" ] || unknown "no onboarded repo '$SLUG' (expected projects/$SLUG.yml)"
REPO="$(sed -nE 's/^repo:[[:space:]]*(.+)/\1/p' "$MANIFEST" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1)"
[ -n "$REPO" ] || unknown "projects/$SLUG.yml has no repo: field"
command -v gh >/dev/null 2>&1 || unknown "gh not found"

if [ "$KIND" = checker ]; then
  JSON="$(gh pr view "$NUM" -R "$REPO" --json comments 2>/dev/null)" \
    || unknown "\`gh pr view $NUM -R $REPO --json comments\` failed"
else
  JSON="$(gh issue view "$NUM" -R "$REPO" --json comments 2>/dev/null)" \
    || unknown "\`gh issue view $NUM -R $REPO --json comments\` failed"
fi
# The shared counters fail soft (garbage -> 0); validate first so "could not count"
# never reads as "zero rounds, go ahead".
printf '%s' "$JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("comments"), list)' \
  2>/dev/null || unknown "gh returned no parseable comments JSON"

if [ "$KIND" = checker ]; then
  n="$(printf '%s' "$JSON" | checker_rounds_this_generation)"
  what="checker $SLUG PR #$NUM: $n/$CHECKER_LIMIT rounds this review generation (CHECKER_LIMIT)"
  if [ "$n" -ge "$CHECKER_LIMIT" ]; then
    echo "round-cap: refuse — $what — another checker would exceed the cap; stop and ask the operator"
    exit 3
  fi
else
  counts="$(printf '%s' "$JSON" | worker_no_finish_counts)"
  hard="${counts%% *}" nwait="${counts##* }"
  what="worker $SLUG#$NUM: $hard/$WORKER_LIMIT interrupted/unfinalized (WORKER_LIMIT), $nwait/$WORKER_WAIT_LIMIT exit-to-wait (WORKER_WAIT_LIMIT) trailing attempts"
  if [ "$hard" -ge "$WORKER_LIMIT" ] || [ "$nwait" -ge "$WORKER_WAIT_LIMIT" ]; then
    echo "round-cap: refuse — $what — another worker would exceed the cap; stop and ask the operator"
    exit 3
  fi
fi
echo "round-cap: allow — $what"
exit 0
