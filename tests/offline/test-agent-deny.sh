#!/usr/bin/env bash
# test-agent-deny.sh (offline) — `Agent` (subagent delegation) must be denied in every
# UNATTENDED dispatch, and must NOT be denied in the human-present interactive one.
#
# Why this is a test and not `--dry-run` eyeballing (issue #45): the deny is a safety-model
# invariant with a silent failure mode. If someone "simplifies" `Agent` out of a
# --disallowedTools list, nothing breaks loudly — a worker just silently regains the
# ability to spawn a subagent that runs with no brief, outside the Stop-hook exit
# contract, on the same --max-budget-usd, in a bypassPermissions session with nobody
# watching. Nothing in a log would show it (with --output-format json the log holds only
# the final result object), so this assertion is the only alarm.
#
# Two dispatches are checked end-to-end by running the real launcher with --dry-run in a
# throwaway sandbox (no network: --dry-run returns before any git/worktree work, and the
# checker's one `gh pr view` is served by a stub on PATH). The third — the headless cycle
# orchestrator in orchestrator-cycle.sh — cannot be dry-run offline (its --dry-run is
# plan-only and still boots a real, billed `claude` session), so it is asserted at the
# source level against the single flag on its invocation.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

# count_flag_uses FILE — how many times FILE actually *passes* --disallowedTools, ignoring
# comment lines (this repo comments the flag heavily, so a raw grep -c over-counts).
# grep -c exits 1 on zero matches, hence the `|| true`; explicit `return 0` per CLAUDE.md
# so a zero count can never abort a `set -e` caller.
count_flag_uses() {
  grep -- '--disallowedTools' "$1" 2>/dev/null | grep -c -v '^[[:space:]]*#' || true
  return 0
}

# --- shared sandbox: a throwaway ORCH the launchers resolve as their repo root ------
SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" launch-worker
sandbox_copy_script "$SB" launch-checker
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" config-common
cp -R "$REPO_ROOT/host" "$SB/host"
cp -R "$REPO_ROOT/templates" "$SB/templates"
cp "$REPO_ROOT/briefs/worker-brief.md" "$REPO_ROOT/briefs/checker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-worker.sh" "$SB/bin/launch-checker.sh"

# A code-only manifest (raw_resolved == working_clone) so nothing here implies real data.
CLONE="$(sandbox_tmp)"; WTS="$(sandbox_tmp)"
cat >"$SB/projects/agent-deny-demo.yml" <<YML
repo: test-operator/agent-deny-demo
working_clone: $CLONE
worktrees_dir: $WTS
data_root: $CLONE
raw_resolved: $CLONE
YML

# --- 1. worker --------------------------------------------------------------------
rc=0
worker_out="$("$SB/bin/launch-worker.sh" agent-deny-demo 45 --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "launch-worker --dry-run assembles cleanly in a sandbox" \
  "The worker dry-run should print its assembled command and exit 0 — see bin/launch-worker.sh."
assert_matches "$worker_out" '--disallowedTools( +[A-Za-z]+)* +Agent( |$)' \
  "worker dispatch denies Agent (--disallowedTools … Agent)" \
  "bin/launch-worker.sh build_cmd() must pass --disallowedTools Agent: a subagent escapes the brief, the Stop-hook exit contract, and the budget (issue #45)."

# --- 2. checker -------------------------------------------------------------------
# Stub `gh` so `gh pr view --json …` resolves offline to an OPEN, ready PR closing #45.
GHDIR="$(sandbox_tmp)"
cat >"$GHDIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"isDraft":false,"headRefName":"issue-45","closingIssuesReferences":[{"number":45}],"state":"OPEN"}'
SH
chmod +x "$GHDIR/gh"
rc=0
checker_out="$(PATH="$GHDIR:$PATH" "$SB/bin/launch-checker.sh" agent-deny-demo 1 --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "launch-checker --dry-run assembles cleanly in a sandbox" \
  "The checker dry-run should print its assembled command and exit 0 — see bin/launch-checker.sh."
assert_matches "$checker_out" '--disallowedTools( +[A-Za-z]+)* +Agent( |$)' \
  "checker dispatch denies Agent (--disallowedTools … Agent)" \
  "bin/launch-checker.sh build_cmd() must include Agent in its --disallowedTools list (issue #45)."
# The existing no-mutation denies must survive the extension, and it must stay ONE flag:
# --disallowedTools is variadic, so a second occurrence is parsed ambiguously.
for tool in Edit Write NotebookEdit; do
  assert_matches "$checker_out" "--disallowedTools( +[A-Za-z]+)* +$tool( |\$)" \
    "checker still denies $tool alongside Agent" \
    "Extending the list must not drop the checker's existing no-mutation denies."
done
assert_eq 1 "$(count_flag_uses "$SB/bin/launch-checker.sh" | tr -d ' ')" \
  "checker declares exactly one --disallowedTools flag" \
  "--disallowedTools is variadic — keep every denied tool in the single existing flag."

# --- 3. headless cycle orchestrator (source-level: its --dry-run boots a billed session)
cycle="$REPO_ROOT/bin/orchestrator-cycle.sh"
assert_file_present "$cycle" "bin/orchestrator-cycle.sh present"
cycle_flag="$(grep -- '--disallowedTools' "$cycle" | grep -v '^[[:space:]]*#' || true)"
assert_matches "$cycle_flag" '--disallowedTools( +[A-Za-z]+)* +Agent( |$)' \
  "autonomous cycle orchestrator denies Agent" \
  "bin/orchestrator-cycle.sh must include Agent in its existing --disallowedTools list (issue #45)."
assert_eq 1 "$(count_flag_uses "$cycle" | tr -d ' ')" \
  "cycle orchestrator declares exactly one --disallowedTools flag" \
  "--disallowedTools is variadic — keep every denied tool in the single existing flag."

# --- 4. the interactive orchestrator is deliberately EXEMPT -------------------------
# Human-present: the operator sees each delegation and owns the spend. A deny here would
# only narrow interactive inspection, so its absence is an invariant too, not an omission.
launcher="$REPO_ROOT/bin/launch-orchestrator.sh"
assert_file_present "$launcher" "bin/launch-orchestrator.sh present"
assert_eq 0 "$(count_flag_uses "$launcher" | tr -d ' ')" \
  "interactive orchestrator sets no --disallowedTools (human-present, deliberately exempt)" \
  "bin/launch-orchestrator.sh must stay unrestricted — narrowing it breaks operator inspection (issue #45)."
assert_contains "$(cat "$launcher")" "Agent" \
  "interactive orchestrator's comment records WHY it is exempt from the Agent deny" \
  "Keep the comment explaining that the exemption is deliberate, so it reads as a decision and not an oversight."
