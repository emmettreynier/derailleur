#!/usr/bin/env bash
# test-machine-env.sh (offline) — the worker and checker launchers source the machine's
# shared shell env (~/.bootstrap_env.sh, or $DERAILLEUR_MACHINE_ENV) before the agent
# starts, and a machine without the file is unaffected (issue #93).
#
# Why: every hop on the dispatch path is a non-login `bash -c`, which reads neither
# ~/.profile nor (on stock Ubuntu, which returns early when non-interactive) ~/.bashrc.
# On the DGX that left QUARTO_CHROMIUM unset in every worker, and every headless
# `make draft` died with `ERROR: Chrome not found` while the binary sat installed.
#
# The fixture env file below is SYNTHETIC — a made-up QUARTO_CHROMIUM path, not a real
# install. Nothing here reads the real ~/.bootstrap_env.sh: sandbox.sh points
# DERAILLEUR_MACHINE_ENV at a nonexistent path, and each case overrides it explicitly.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

FIX="$(sandbox_tmp)"
ENV_OK="$FIX/synthetic-bootstrap-env.sh"
cat >"$ENV_OK" <<'SH'
# SYNTHETIC fixture for test-machine-env.sh — not a real machine's env file.
export QUARTO_CHROMIUM=/synthetic/ms-playwright/chromium_headless_shell/chrome-linux/headless_shell
SYNTH_NOT_EXPORTED=1
SH
ENV_FAILS="$FIX/synthetic-env-nonzero.sh"
printf 'export SYNTH_PARTIAL=yes\nfalse\n' >"$ENV_FAILS"
ENV_LOOSE="$FIX/synthetic-env-sets-options.sh"
printf 'set +e +u\nset +o pipefail\nexport SYNTH_LOOSE=1\n' >"$ENV_LOOSE"
SYNTH_QC=/synthetic/ms-playwright/chromium_headless_shell/chrome-linux/headless_shell

# --- 1. helper: the file is sourced, its exports reach a non-login child shell -------
out="$(env -u QUARTO_CHROMIUM DERAILLEUR_MACHINE_ENV="$ENV_OK" bash -c '
  set -euo pipefail
  source "$1/bin/dispatch-common.sh"
  source_machine_env
  echo "status=$MACHINE_ENV_STATUS"
  bash -c "echo child=\${QUARTO_CHROMIUM:-<unset>} unexported=\${SYNTH_NOT_EXPORTED:-<unset>}"
' _ "$REPO_ROOT" 2>&1)"
assert_contains "$out" "status=sourced" "an existing env file is sourced" \
  "source_machine_env (bin/dispatch-common.sh) must source \$DERAILLEUR_MACHINE_ENV when it exists."
assert_contains "$out" "child=$SYNTH_QC" "an exported var reaches the agent's child process" \
  "The launcher's environment is what claude inherits; an exported var must survive into a child."
assert_contains "$out" "unexported=<unset>" "an unexported var does not (documented: only exports reach the agent)"

# --- 2. helper: a missing file is a silent no-op -------------------------------------
out="$(env -u QUARTO_CHROMIUM DERAILLEUR_MACHINE_ENV="$FIX/absent.sh" bash -c '
  set -euo pipefail
  source "$1/bin/dispatch-common.sh"
  source_machine_env
  echo "status=$MACHINE_ENV_STATUS qc=${QUARTO_CHROMIUM:-<unset>}"
' _ "$REPO_ROOT" 2>&1)"
assert_eq "status=absent qc=<unset>" "$out" "a machine without the file is unaffected (no output, nothing set)" \
  "An absent env file must be a no-op: no warning, no variable, rc 0."

# --- 3. helper: strict mode is lifted for the file and restored after ----------------
out="$(DERAILLEUR_MACHINE_ENV="$ENV_LOOSE" bash -c '
  set -euo pipefail
  source "$1/bin/dispatch-common.sh"
  source_machine_env
  echo "flags=$- pipefail=$(shopt -qo pipefail && echo on || echo off) loose=$SYNTH_LOOSE"
' _ "$REPO_ROOT" 2>&1)"
assert_matches "$out" '^flags=[^ ]*e' "errexit is restored after an env file that clears it" \
  "Snapshot -e from \$- (not \$(set +o), which runs with errexit cleared) and restore it."
assert_matches "$out" '^flags=[^ ]*u' "nounset is restored after an env file that clears it"
assert_contains "$out" "pipefail=on" "pipefail is restored after an env file that clears it"
out="$(DERAILLEUR_MACHINE_ENV="$ENV_OK" bash -c '
  source "$1/bin/dispatch-common.sh"
  source_machine_env
  echo "flags=$- pipefail=$(shopt -qo pipefail && echo on || echo off)"
' _ "$REPO_ROOT" 2>&1)"
assert_matches "$out" '^flags=[^ eu]* ' "a caller without -e/-u is not switched into them"
assert_contains "$out" "pipefail=off" "a caller without pipefail is not switched into it"

# --- 4. helper: a nonzero status from the file warns but does not abort --------------
rc=0
out="$(DERAILLEUR_MACHINE_ENV="$ENV_FAILS" bash -c '
  set -euo pipefail
  source "$1/bin/dispatch-common.sh"
  source_machine_env
  echo "after status=$MACHINE_ENV_STATUS partial=$SYNTH_PARTIAL"
' _ "$REPO_ROOT" 2>&1)" || rc=$?
assert_rc 0 "$rc" "an env file ending nonzero does not abort a set -e launcher"
assert_contains "$out" "after status=sourced (status 1) partial=yes" "its status is recorded and its exports kept"
assert_contains "$out" "warning: machine env" "and a warning names it on stderr"

# --- 5/6. both launchers, end to end on --dry-run ------------------------------------
SB="$(new_sandbox)"
write_filled_conf "$SB"
for s in launch-worker launch-checker dispatch-common config-common; do sandbox_copy_script "$SB" "$s"; done
cp -R "$REPO_ROOT/host" "$SB/host"
cp -R "$REPO_ROOT/templates" "$SB/templates"
cp "$REPO_ROOT/briefs/worker-brief.md" "$REPO_ROOT/briefs/checker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-worker.sh" "$SB/bin/launch-checker.sh"
CLONE="$(sandbox_tmp)"; WTS="$(sandbox_tmp)"
cat >"$SB/projects/machine-env-demo.yml" <<YML
repo: test-operator/machine-env-demo
working_clone: $CLONE
worktrees_dir: $WTS
data_root: $CLONE
raw_resolved: $CLONE
YML
GHDIR="$(sandbox_tmp)"
cat >"$GHDIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"isDraft":false,"headRefName":"issue-93","closingIssuesReferences":[{"number":93}],"state":"OPEN"}'
SH
chmod +x "$GHDIR/gh"

for role in worker checker; do
  n=93; [ "$role" = checker ] && n=1
  rc=0
  out="$(env -u QUARTO_CHROMIUM PATH="$GHDIR:$PATH" DERAILLEUR_MACHINE_ENV="$ENV_OK" \
         "$SB/bin/launch-$role.sh" machine-env-demo "$n" --dry-run 2>&1)" || rc=$?
  assert_rc 0 "$rc" "launch-$role --dry-run runs with a machine env file present"
  assert_contains "$out" "#   machine env   : $ENV_OK (sourced)   QUARTO_CHROMIUM=$SYNTH_QC" \
    "launch-$role sources the machine env before the agent starts and reports QUARTO_CHROMIUM" \
    "bin/launch-$role.sh must call source_machine_env before dispatch and print the machine env line."
  rc=0
  out="$(env -u QUARTO_CHROMIUM PATH="$GHDIR:$PATH" DERAILLEUR_MACHINE_ENV="$FIX/absent.sh" \
         "$SB/bin/launch-$role.sh" machine-env-demo "$n" --dry-run 2>&1)" || rc=$?
  assert_rc 0 "$rc" "launch-$role --dry-run runs with no machine env file"
  assert_contains "$out" "#   machine env   : $FIX/absent.sh (absent)   QUARTO_CHROMIUM=<unset>" \
    "launch-$role on a machine without the file reports it absent and sets nothing"
done
