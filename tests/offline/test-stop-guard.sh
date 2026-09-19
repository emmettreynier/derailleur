#!/usr/bin/env bash
# test-stop-guard.sh (offline) — host/hooks/worker-stop-guard.sh, the Stop hook that
# enforces the worker exit contract mechanically (issue #78; the hook had no coverage
# at all before this file).
#
# The hook is where the pressure to fabricate is structural: it refuses to let a
# worker session end until a PR exists or the issue carries `needs-input`, so its
# block reason is the last thing a worker whose retrieval genuinely failed reads.
# The contract asserted here:
#   (1) no PR + no needs-input            -> {"decision":"block"} on stdout, exit 0
#   (2) the block reason names the honest-failure exit (needs-input is a legitimate,
#       successful finish) and forbids inventing a result to satisfy the hook
#   (3) a PR on the branch                -> exit 0, no decision  (shipped/working)
#   (4) the needs-input label present     -> exit 0, no decision  (blocked/escalated)
#   (5) stop_hook_active: true            -> exit 0, no decision  (single-nudge guard)
#
# Everything runs against a throwaway temp git repo + a PATH-shimmed `gh`: no real
# repo, no real GitHub call, no network. The shim is driven by two env vars the test
# sets per case, so one shim covers every combination.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

HOOK="$REPO_ROOT/host/hooks/worker-stop-guard.sh"
[ -f "$HOOK" ] || fail "no $HOOK to test" "The hook under test is missing from host/hooks/."

ISSUE=78
REPO="test-owner/test-repo"

# --- a throwaway git repo to stand in for the worker's worktree ---------------
WT="$(sandbox_tmp)/worktree"
mkdir -p "$WT"
git init -q "$WT"
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
BRANCH="$(git -C "$WT" branch --show-current)"
[ -n "$BRANCH" ] || fail "sandbox git repo reports no current branch" \
  "The hook keys off \`git branch --show-current\`; the fixture must have one."

# --- a `gh` shim driven by GH_PR_COUNT / GH_LABELS ----------------------------
# Answers exactly the two calls the hook makes (pr list --json number --jq length,
# issue view --json labels --jq '.labels[].name') and nothing else.
SHIM="$(sandbox_tmp)"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)    printf '%s\n' "${GH_PR_COUNT:-0}" ;;
  issue) [ -n "${GH_LABELS:-}" ] && printf '%s\n' "$GH_LABELS" ;;
  *)     exit 1 ;;
esac
exit 0
SH
chmod +x "$SHIM/gh"

# payload CWD ACTIVE — the Stop-hook JSON the harness feeds on stdin.
payload() {
  python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1], "stop_hook_active": sys.argv[2] == "true"}))' \
    "$1" "$2"
}

# run_hook PR_COUNT LABELS STOP_ACTIVE — run the hook and set OUT + RC in the CALLER's
# shell. Deliberately not `out=$(run_hook …)`: that runs the function in a subshell, so
# an rc it assigned would never reach the caller (bash 3.2 has no other way back).
OUT=""; RC=0
run_hook() {
  local f="$SHIM/hook-stdout"
  RC=0
  PATH="$SHIM:$PATH" GH_PR_COUNT="$1" GH_LABELS="$2" \
    bash "$HOOK" "$ISSUE" "$REPO" <<<"$(payload "$WT" "$3")" >"$f" || RC=$?
  OUT="$(cat "$f")"
  return 0
}

# decision_of JSON — echo the .decision field ("" when there is no JSON at all).
decision_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
print(json.loads(raw).get("decision", "") if raw else "")
' 2>/dev/null || printf ''
}

# --- (1) no PR, no needs-input -> block ---------------------------------------
run_hook 0 "" false; out="$OUT"
assert_rc 0 "$RC" "no PR + no needs-input: hook still exits 0 (it signals via JSON)" \
  "A Stop hook communicates with {\"decision\":\"block\"} on stdout, not an exit code."
assert_eq "block" "$(decision_of "$out")" \
  "no PR + no needs-input: decision is block" \
  "The hook must refuse a stop that left no trail — see design.md, the Stop-hook paragraph."

# --- (2) the block reason names the honest-failure exit ------------------------
reason="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))')"
assert_contains "$reason" "needs-input" \
  "block reason names the needs-input exit" \
  "The escalation route must be named, or the worker only sees 'open a PR'."
assert_contains "$reason" "SUCCESSFUL" \
  "block reason says the escalation exit is a successful finish" \
  "issue #78: a truthful 'I could not do this' must read as success, not as failure to hide."
assert_contains "$reason" "unachievable" \
  "block reason covers a criterion unachievable as written" \
  "A worker whose criterion cannot be met must recognize itself in the reason."
assert_contains "$reason" "invent" \
  "block reason forbids inventing a result to satisfy the hook" \
  "This hook is the fabrication pressure; it must say so itself."

# --- (3) a PR on the branch -> allow ------------------------------------------
run_hook 1 "" false; out="$OUT"
assert_rc 0 "$RC" "PR exists: exit 0" "The shipped/working exit must be allowed."
assert_eq "" "$out" "PR exists: no decision emitted (stop allowed)" \
  "Any stdout from a Stop hook is read as a decision — the allow path must print nothing."

# --- (4) needs-input label present -> allow -----------------------------------
run_hook 0 "needs-input" false; out="$OUT"
assert_rc 0 "$RC" "needs-input label: exit 0" "The blocked/escalated exit must be allowed."
assert_eq "" "$out" "needs-input label: no decision emitted (stop allowed)" \
  "A worker that escalated honestly must not be blocked from stopping."

# A near-miss label must NOT satisfy the exit (the hook greps -qx, not a substring).
run_hook 0 "needs-input-later" false; out="$OUT"
assert_eq "block" "$(decision_of "$out")" \
  "a label merely containing 'needs-input' does not satisfy the exit" \
  "The hook matches the label exactly (grep -qx); loosening that would let any label through."

# --- (5) stop_hook_active: true -> allow (single-nudge guard) ------------------
run_hook 0 "" true; out="$OUT"
assert_rc 0 "$RC" "stop_hook_active: exit 0" \
  "The documented guard against Stop-hook loops must stay intact."
assert_eq "" "$out" "stop_hook_active: no decision emitted (one nudge only)" \
  "A second block would trap the worker burning budget — see design.md."
