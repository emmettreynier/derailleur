#!/usr/bin/env bash
# test-checker-rounds.sh (offline) — the checker-round cap that stops a PR from being
# re-checked forever (issue #52, extending #40).
#
# What it holds:
#   * every lead the poster can emit is in the ONE `CHECKER_ROUND_LEADS` list the
#     counter reads — the regression this issue exists to prevent is a lead added to
#     `finalize_dispatch` that `orchestrator-cycle.sh` never learns to count;
#   * `checker_rounds_this_generation` counts interrupted rounds alongside incomplete
#     ones and verdicts, and only a TO-OPERATOR verdict ends a generation;
#   * `orchestrator-cycle.sh` reaches CHECKER_LIMIT (and escalates) on a trailing run of
#     interrupted rounds, exactly as it does on verdicts.
#
# Hermetic: pure fixture JSON piped into a sourced sandbox copy of dispatch-common.sh.
# No `gh`, no network, nothing dispatched, nothing spent.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/dispatch-common.sh" "bin/dispatch-common.sh present" \
  "The shared post-run helpers are missing from bin/."
assert_file_present "$REPO_ROOT/bin/orchestrator-cycle.sh" "bin/orchestrator-cycle.sh present" \
  "The cycle script is missing from bin/."

# Source a SANDBOXED COPY (see test-finalize-complete.sh): record_usage_reset resolves
# its repo root from BASH_SOURCE, so sourcing the real file lets a test write state into
# the operator's live checkout.
SB="$(new_sandbox)"
sandbox_copy_script "$SB" dispatch-common
. "$SB/bin/dispatch-common.sh"

# --- the leads are enumerated once, and cover everything the poster emits ----------
for lead in '**Checker verdict:' '**Checker incomplete:' '**Checker interrupted:'; do
  assert_contains "$CHECKER_ROUND_LEADS" "$lead" \
    "CHECKER_ROUND_LEADS includes '$lead'" \
    "A lead the poster emits but the counter doesn't know = an uncountable round (issue #52)."
done

POSTER="$(cat "$REPO_ROOT/bin/dispatch-common.sh")"
assert_contains "$POSTER" '**Checker interrupted: $st**' \
  "finalize_dispatch posts a '**Checker interrupted:' body" \
  "An interrupted checker must leave a countable comment, mirroring the worker path."
assert_contains "$POSTER" '**Checker incomplete: $st**' \
  "finalize_dispatch still posts a '**Checker incomplete:' body" \
  "The #40 lead must survive the #52 addition."

CYCLE="$(cat "$REPO_ROOT/bin/orchestrator-cycle.sh")"
assert_contains "$CYCLE" "checker_rounds_this_generation" \
  "orchestrator-cycle.sh counts rounds through the shared helper" \
  "A second, independently-maintained lead list is exactly the drift this issue fixes."
assert_not_contains "$CYCLE" '"**Checker verdict"' \
  "orchestrator-cycle.sh keeps no private copy of the lead list" \
  "The leads must be enumerated once, in dispatch-common.sh."

# --- counting -----------------------------------------------------------------------
# rounds <body> [<body> …] -> the JSON `gh pr view --json comments` would emit.
rounds() {
  python3 -c '
import json, sys
print(json.dumps({"comments": [{"body": b} for b in sys.argv[1:]]}))' "$@"
}
count() { rounds "$@" | checker_rounds_this_generation; }

assert_eq "0" "$(count)" \
  "a PR with no comments has 0 rounds" \
  "An empty history must count zero, never escalate."
assert_eq "0" "$(printf 'not json at all' | checker_rounds_this_generation)" \
  "unparseable comment JSON counts 0" \
  "A flaky gh must fail soft — never escalate a PR on a parse error."
assert_eq "0" "$(count 'A plain human comment' '🔁 some bot noise')" \
  "non-round comments are not counted" \
  "Only the CHECKER_ROUND_LEADS bodies constitute a round."

# The runaway this issue closes: CHECKER_LIMIT (default 4) trailing INTERRUPTED rounds.
INT='**Checker interrupted: interrupted-ratelimit**. The session was cut off.'
assert_eq "4" "$(count "$INT" "$INT" "$INT" "$INT")" \
  "four interrupted rounds count as four" \
  "Before #52 these counted as ZERO and the PR was re-checked every cycle forever."

# Mixed interrupted + incomplete ride the SAME cap (no separate knob — the non-goal).
INC='**Checker incomplete: incomplete-noverdict**. The session exited cleanly.'
assert_eq "4" "$(count "$INT" "$INC" "$INT" "$INC")" \
  "interrupted and incomplete rounds share one cap" \
  "CHECKER_LIMIT counts both classes; a separate knob was an explicit non-goal."

# Generation reset: only a TO-OPERATOR verdict ends one.
assert_eq "1" "$(count "$INT" "$INC" '**Checker verdict: `pass`** …' "$INT")" \
  "a pass verdict ends the generation and resets the count" \
  "Rounds are counted per generation — only rounds AFTER the last to-operator verdict."
assert_eq "0" "$(count "$INT" "$INT" '**Checker verdict: blocked**')" \
  "a blocked verdict ends the generation (nothing after it)" \
  "pass / pass_with_findings / blocked all hand the ball to the operator."
assert_eq "3" "$(count "$INT" '**Checker verdict: changes_requested** …' "$INC")" \
  "changes_requested does NOT end a generation" \
  "It keeps the ball worker-side, so its round still counts (unchanged semantics)."

# --- the escalation predicate ---------------------------------------------------------
# orchestrator-cycle.sh escalates when NROUNDS >= CHECKER_LIMIT. Asserted against the
# script's own default so a changed default can't silently un-test this.
CHECKER_LIMIT="$(sed -nE 's/^CHECKER_LIMIT="\$\{CHECKER_LIMIT:-([0-9]+)\}"$/\1/p' \
                   "$REPO_ROOT/bin/orchestrator-cycle.sh" | head -1)"
case "${CHECKER_LIMIT:-}" in
  ''|*[!0-9]*) fail "could not read the CHECKER_LIMIT default from bin/orchestrator-cycle.sh" \
                    "The test derives the cap from the script; keep the CHECKER_LIMIT=\${CHECKER_LIMIT:-N} shape." ;;
esac

TRAILING=""
i=0
while [ "$i" -lt "$CHECKER_LIMIT" ]; do TRAILING="$TRAILING$INT"$'\n'; i=$((i+1)); done
N="$(python3 -c '
import json, sys
bodies = [b for b in sys.stdin.read().split("\n") if b]
print(json.dumps({"comments": [{"body": b} for b in bodies]}))' <<<"$TRAILING" \
     | checker_rounds_this_generation)"
if [ "$N" -ge "$CHECKER_LIMIT" ]; then
  pass "$CHECKER_LIMIT trailing interrupted rounds reach CHECKER_LIMIT -> escalate to needs-input"
else
  fail "$CHECKER_LIMIT trailing interrupted rounds counted only $N — the cap never trips" \
       "orchestrator-cycle.sh escalates on NROUNDS >= CHECKER_LIMIT; interrupted rounds must count."
fi

# One fewer must NOT trip it (no over-eager escalation).
TRAILING=""
i=1
while [ "$i" -lt "$CHECKER_LIMIT" ]; do TRAILING="$TRAILING$INT"$'\n'; i=$((i+1)); done
N="$(python3 -c '
import json, sys
bodies = [b for b in sys.stdin.read().split("\n") if b]
print(json.dumps({"comments": [{"body": b} for b in bodies]}))' <<<"$TRAILING" \
     | checker_rounds_this_generation)"
if [ "$N" -lt "$CHECKER_LIMIT" ]; then
  pass "$((CHECKER_LIMIT-1)) interrupted rounds stay under the cap (no early escalation)"
else
  fail "$((CHECKER_LIMIT-1)) interrupted rounds already reached the cap ($N)" \
       "The cap must trip AT CHECKER_LIMIT, not before."
fi
