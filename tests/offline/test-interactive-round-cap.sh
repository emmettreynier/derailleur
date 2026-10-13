#!/usr/bin/env bash
# test-interactive-round-cap.sh (OFFLINE) — bin/round-cap.sh, the interactive path's
# round-cap check (issue #91), against a recording `gh` shim that serves fixture
# PR / issue comments.
#
# What it holds:
#   * CHECKER_LIMIT=4: 3 counted rounds -> allow (exit 0), 4 -> refuse (exit 3); a
#     to-operator verdict starts a new generation, exactly as orchestrator-cycle.sh counts;
#   * WORKER_LIMIT=4: 3 hard-class trailing attempts -> allow, 4 -> refuse;
#   * `incomplete-waiting` counts ONLY against WORKER_WAIT_LIMIT (4 waits -> allow, 10 ->
#     refuse), and an intervening comment resets both;
#   * a failing `gh` and an unparseable reply are `unknown` (exit 1), never "0, go ahead";
#   * the check writes nothing — every gh call it makes is a read (`pr view` / `issue
#     view`), never `issue edit` / `pr edit` / a comment;
#   * it reuses the shared counters rather than reimplementing them.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 \
  || { skip "python3 not installed — skipping round-cap"; exit 0; }

SRC="$(cat "$REPO_ROOT/bin/round-cap.sh")"
assert_contains "$SRC" "checker_rounds_this_generation" \
  "round-cap.sh counts checker rounds through the shared helper" \
  "Reuse dispatch-common.sh's counter; a second lead list is the drift #52 fixed."
assert_contains "$SRC" "worker_no_finish_counts" \
  "round-cap.sh counts worker attempts through the shared helper"
assert_contains "$(cat "$REPO_ROOT/bin/ledger-prune.sh")" "worker_no_finish_counts" \
  "ledger-prune.sh reads the SAME worker counter (one classifier, two callers)"
assert_not_contains "$SRC" "--add-label" "round-cap.sh contains no label write"

SB="$(new_sandbox)"
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" round-cap
write_project_manifest "$SB" fixture "test-operator/fixture"

SHIM="$(sandbox_tmp)"
CALLS="$_SANDBOX_ROOT/gh-calls.log"
COMMENTS="$_SANDBOX_ROOT/comments.json"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr view"|"issue view")
    case "${GH_MODE:-ok}" in
      fail)    echo "gh: HTTP 502" >&2; exit 1 ;;
      garbage) echo "not json" ;;
      *)       cat "$GH_COMMENTS" ;;
    esac ;;
  *) echo "gh shim: unexpected call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$SHIM/gh"

comments() {  # <body> ... -> the JSON `gh … view --json comments` emits
  python3 -c '
import json, sys
print(json.dumps({"comments": [{"body": b} for b in sys.argv[2:]]}))' x "$@" >"$COMMENTS"
}
rep() { local n="$1" b="$2" i; for i in $(seq 1 "$n"); do printf '%s\n' "$b"; done; }

# check <kind> <num>  -> sets OUT and RC
check() {
  set +e
  OUT="$(PATH="$SHIM:$PATH" GH_CALLS="$CALLS" GH_COMMENTS="$COMMENTS" \
           CHECKER_LIMIT=4 WORKER_LIMIT=4 WORKER_WAIT_LIMIT=10 \
           "$SB/bin/round-cap.sh" "$1" fixture "$2" 2>&1)"
  RC=$?
  set -e
}
: >"$CALLS"

CV='**Checker verdict: `changes_requested`**'
CI='**Checker interrupted: interrupted-ratelimit**'
CN='**Checker incomplete: incomplete-noverdict**'
PASSV='**Checker verdict: `pass`**'

# --- checker ---------------------------------------------------------------------
comments "$CV" "$CI" "$CN"
check checker 21
assert_rc 0 "$RC" "checker: 3 counted rounds with CHECKER_LIMIT=4 -> allowed"
assert_contains "$OUT" "round-cap: allow" "…and says allow"
assert_contains "$OUT" "3/4" "…reporting the count against the limit"

comments "$CV" "$CI" "$CN" "$CV"
check checker 21
assert_rc 3 "$RC" "checker: 4 counted rounds -> refused (exit 3)"
assert_contains "$OUT" "round-cap: refuse" "…and says refuse"
assert_contains "$OUT" "CHECKER_LIMIT" "…naming the cap"
assert_contains "$OUT" "stop and ask the operator" "…and that the caller stops and asks"

comments "$CV" "$CV" "$CV" "$CV" "$PASSV" "$CV"
check checker 21
assert_rc 0 "$RC" "checker: a to-operator verdict ends the generation (1 round after it -> allowed)"

# --- worker ----------------------------------------------------------------------
WI='**Worker interrupted: interrupted-budget**'
WN='**Worker incomplete: incomplete-nopr**'
WW='**Worker incomplete: incomplete-waiting**'

comments "$WI" "$WN" "$WI"
check worker 7
assert_rc 0 "$RC" "worker: 3 hard-class attempts with WORKER_LIMIT=4 -> allowed"
comments "$WI" "$WN" "$WI" "$WN"
check worker 7
assert_rc 3 "$RC" "worker: 4 hard-class attempts -> refused"
assert_contains "$OUT" "4/4 interrupted/unfinalized (WORKER_LIMIT)" "…naming WORKER_LIMIT"

comments "$WW" "$WW" "$WW" "$WW"
check worker 7
assert_rc 0 "$RC" "worker: 4 incomplete-waiting do NOT count against WORKER_LIMIT=4"
assert_contains "$OUT" "0/4 interrupted/unfinalized" "…hard count stays 0"
assert_contains "$OUT" "4/10 exit-to-wait" "…they count against WORKER_WAIT_LIMIT"
IFS=$'\n'; comments $(rep 9 "$WW"); unset IFS
check worker 7
assert_rc 0 "$RC" "worker: 9 waits with WORKER_WAIT_LIMIT=10 -> allowed"
IFS=$'\n'; comments $(rep 10 "$WW"); unset IFS
check worker 7
assert_rc 3 "$RC" "worker: 10 waits -> refused on WORKER_WAIT_LIMIT"
assert_contains "$OUT" "10/10 exit-to-wait (WORKER_WAIT_LIMIT)" "…naming WORKER_WAIT_LIMIT"

comments "$WI" "$WN" "$WI" "$WN" "a human reply"
check worker 7
assert_rc 0 "$RC" "worker: an intervening comment resets the trailing count"

# --- unknown, never "0, go ahead" ------------------------------------------------
GH_MODE=fail; export GH_MODE
check checker 21
assert_rc 1 "$RC" "a failing gh is reported unknown (exit 1), not allow"
assert_contains "$OUT" "round-cap: unknown" "…and says unknown"
GH_MODE=garbage
check worker 7
assert_rc 1 "$RC" "an unparseable gh reply is unknown, not a zero count"
unset GH_MODE
set +e
OUT="$(PATH="$SHIM:$PATH" GH_CALLS="$CALLS" "$SB/bin/round-cap.sh" worker nosuch 1 2>&1)"; RC=$?
set -e
assert_rc 1 "$RC" "an un-onboarded slug is unknown"
set +e
"$SB/bin/round-cap.sh" bogus fixture 1 >/dev/null 2>&1; RC=$?
set -e
assert_rc 2 "$RC" "a bad kind is a usage error"

# --- read-only ---------------------------------------------------------------------
assert_eq "" "$(grep -vE '^(pr view|issue view) [0-9]+ -R test-operator/fixture --json comments$' "$CALLS" || true)" \
  "every gh call round-cap made was a comments READ" \
  "The interactive path stops and asks on a tripped cap; it must never apply a label itself."
