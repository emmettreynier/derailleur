#!/usr/bin/env bash
# test-config-guard.sh (offline) — the operator-identity guard in config-common.sh,
# across all three states, plus {{OPERATOR_NAME}} brief rendering the way the
# launchers do. Migrated from smoke-test.sh checks (a)/(b)/(c). Deterministic,
# offline, throwaway confs only.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

CONFIG_COMMON="$REPO_ROOT/bin/config-common.sh"
CHECKER_BRIEF="$REPO_ROOT/briefs/checker-brief.md"
CONF_EXAMPLE="$REPO_ROOT/orchestrator.conf.example"
assert_file_present "$CONFIG_COMMON" "config-common.sh present" \
  "The sourced identity loader is missing from bin/."

# Run the guard against a conf root in a subshell (so its `exit 1` can't kill us),
# with the identity vars unset so nothing leaks from the parent env.
guard_run() {  # $1 = conf root; echoes combined stdout+stderr, returns guard's exit
  (
    ORCH="$1" ORCH_DIR="$1"
    unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
    . "$CONFIG_COMMON"
  ) 2>&1
}

# --- (a) missing conf → nonzero exit + copy-the-example guidance --------------
MISSING="$(sandbox_tmp)"
[ -f "$CONF_EXAMPLE" ] && cp "$CONF_EXAMPLE" "$MISSING/orchestrator.conf.example"
rc=0; out="$(guard_run "$MISSING")" || rc=$?
assert_ne 0 "$rc" "missing conf → guard aborts nonzero" \
  "bin/config-common.sh must abort when the conf is absent."
assert_contains "$out" "orchestrator.conf" "missing-conf abort mentions orchestrator.conf" \
  "The abort message should tell a labmate to copy the example."

# --- (b) one field blank → nonzero exit that NAMES the blank field ------------
BLANK="$(sandbox_tmp)"
write_blank_conf "$BLANK" PR_OWNER
rc=0; out="$(guard_run "$BLANK")" || rc=$?
assert_ne 0 "$rc" "blank field → guard aborts nonzero" \
  "bin/config-common.sh must reject any blank identity field."
assert_contains "$out" "PR_OWNER" "blank-field abort names the blank field (PR_OWNER)" \
  "The message must name which field is blank so it can be found and filled."

# --- (c) all filled → exit 0, all 5 vars EXPORTED, rendered into a brief -------
FILLED="$(sandbox_tmp)"
write_filled_conf "$FILLED"
rc=0
render_out="$(
  ORCH="$FILLED" ORCH_DIR="$FILLED"
  unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
  . "$CONFIG_COMMON"   # exits 1 if the guard rejects the filled conf
  bash -c 'for v in OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT; do
             [ -n "${!v:-}" ] || { echo "NOT-EXPORTED:$v" >&2; exit 3; }
           done' || exit 3
  BRIEF_OPERATOR_NAME="$OPERATOR_NAME" python3 - "$CHECKER_BRIEF" <<'PY'
import os, re, sys
text = re.sub(r'^<!--.*?-->\n', '', open(sys.argv[1]).read(), count=1, flags=re.S)
sys.stdout.write(re.sub(r'{{(\w+)}}',
    lambda m: os.environ.get('BRIEF_' + m.group(1), m.group(0)), text))
PY
)" || rc=$?
assert_rc 0 "$rc" "filled conf → exit 0 and all 5 identity vars exported" \
  "A valid conf must exit 0 and export all 5 identity vars for child processes."
assert_contains "$render_out" "Test Operator" "{{OPERATOR_NAME}} renders into the checker brief" \
  "The launchers substitute {{OPERATOR_NAME}} from the conf; that path is broken."
assert_not_contains "$render_out" "{{OPERATOR_NAME}}" "no unrendered {{OPERATOR_NAME}} token remains after render" \
  "Token substitution in the brief renderer is not replacing OPERATOR_NAME."
