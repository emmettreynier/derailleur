#!/usr/bin/env bash
# test-schedule-pause.sh (offline) — `schedule.sh pause` is DURABLE across reboot/logout
# (issue #90). Before the fix, pause only ran `launchctl bootout`, which unloads the job
# from the current launchd session; launchd reloaded the plist at the next login and the
# loop resumed LIVE. Now pause writes state/paused (which run-cycle.sh exits on) and sets
# launchd's persistent disable flag. Pinned here, with `launchctl` stubbed by a stateful
# shim (a `loaded` + `disabled` flag file, every call logged) and pmset/sudo stubbed so
# nothing touches the real launchd domain, power schedule, or ~/Library (HOME is the
# sandbox). Bash-3.2 safe.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" schedule
mkdir -p "$SB/host/LaunchAgents" "$SB/home"
cp "$REPO_ROOT/host/LaunchAgents/orchestrator.plist" "$SB/host/LaunchAgents/orchestrator.plist"
SCHED="$SB/bin/schedule.sh"
LABEL="com.test-operator.orchestrator"
PLIST_DST="$SB/home/Library/LaunchAgents/$LABEL.plist"
PAUSE="$SB/state/paused"

# --- stubs --------------------------------------------------------------------
STUB="$(sandbox_tmp)"
LSTATE="$(sandbox_tmp)"        # launchd's simulated state: files `loaded`, `disabled`
CALLS="$LSTATE/calls"
cat >"$STUB/launchctl" <<'SH'
#!/usr/bin/env bash
# Stateful launchctl shim. Mirrors the real verbs' observable contract closely enough
# for schedule.sh: bootout fails when not loaded; bootstrap fails when disabled or
# already loaded; print-disabled lists the label when the disable flag is set.
echo "$*" >>"$LSTATE/calls"
case "$1" in
  print)          [ -f "$LSTATE/loaded" ] ;;
  print-disabled) [ -f "$LSTATE/disabled" ] && echo "	\"$TEST_LABEL\" => disabled"; exit 0 ;;
  disable)        [ -f "$LSTATE/fail-disable" ] && exit 1; touch "$LSTATE/disabled" ;;
  enable)         rm -f "$LSTATE/disabled" ;;
  bootout)        [ -f "$LSTATE/loaded" ] || exit 3; rm -f "$LSTATE/loaded" ;;
  bootstrap)      { [ -f "$LSTATE/disabled" ] || [ -f "$LSTATE/loaded" ]; } && exit 5; touch "$LSTATE/loaded" ;;
  *)              exit 0 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/pmset"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/sudo"    # sudo -n never succeeds
chmod +x "$STUB/launchctl" "$STUB/pmset" "$STUB/sudo"

run_sched() {
  HOME="$SB/home" LSTATE="$LSTATE" TEST_LABEL="$LABEL" PATH="$STUB:$PATH" "$SCHED" "$@" 2>&1
}
reset_calls() { : >"$CALLS"; }
calls() { cat "$CALLS" 2>/dev/null || true; }

# --- install (not paused) loads the job --------------------------------------
reset_calls
rc=0; out="$(run_sched install)" || rc=$?
assert_rc 0 "$rc" "install (not paused) exits 0"
assert_file_present "$PLIST_DST" "install renders the plist into the sandbox HOME"
assert_file_present "$LSTATE/loaded" "install bootstraps the job"

rc=0; out="$(run_sched status)" || rc=$?
assert_contains "$out" "loaded: $LABEL" "status: loaded job reports 'loaded'"
assert_not_contains "$out" "PAUSED" "status: a loaded, unpaused job is not reported paused"

# --- pause from loaded: durable state + disable + bootout --------------------
reset_calls
rc=0; out="$(run_sched pause)" || rc=$?
assert_rc 0 "$rc" "pause exits 0"
assert_file_present "$PAUSE" "pause writes the durable marker state/paused" \
  "cmd_pause must write PAUSE_FILE — bootout alone does not survive a reboot (issue #90)."
assert_contains "$(calls)" "disable gui/" "pause calls 'launchctl disable' (launchd-persisted)"
assert_contains "$(calls)" "bootout gui/" "pause still boots the job out of the current session"
assert_file_present "$LSTATE/disabled" "launchd disable flag is set after pause"
assert_file_absent "$LSTATE/loaded" "job is unloaded after pause"
assert_contains "$out" "paused — durable" "pause headline says paused (durable)"
assert_not_contains "$out" "already paused" "first pause does not claim 'already paused'"

# --- a second pause reports from the durable marker, keeps its timestamp ------
since="$(cat "$PAUSE")"
rc=0; out="$(run_sched pause)" || rc=$?
assert_rc 0 "$rc" "repeat pause exits 0"
assert_contains "$out" "already paused (since $since" "repeat pause reports 'already paused' from the marker"
assert_eq "$since" "$(cat "$PAUSE")" "repeat pause does not rewrite the marker's timestamp"

# --- status while paused: from the durable source ----------------------------
rc=0; out="$(run_sched status)" || rc=$?
assert_contains "$out" "PAUSED since $since" "status reports PAUSED from state/paused"
assert_contains "$out" "launchd disable flag: set" "status reports the launchd disable flag"
assert_not_contains "$out" "NOT installed" "status distinguishes paused from not-installed"

# A paused job that got loaded anyway (manual bootstrap / launchd quirk) is flagged.
touch "$LSTATE/loaded"
rc=0; out="$(run_sched status)" || rc=$?
assert_contains "$out" "job is loaded anyway" "status flags a paused-but-loaded job"
rm -f "$LSTATE/loaded"

# --- install while paused keeps the pause ------------------------------------
reset_calls
rm -f "$PLIST_DST"
rc=0; out="$(run_sched install)" || rc=$?
assert_rc 0 "$rc" "install while paused exits 0"
assert_file_present "$PAUSE" "install while paused keeps state/paused"
assert_file_present "$PLIST_DST" "install while paused still re-renders the plist"
assert_not_contains "$(calls)" "bootstrap" "install while paused does NOT bootstrap the job" \
  "cmd_install must not silently un-pause (issue #90)."
assert_contains "$(calls)" "disable gui/" "install while paused re-asserts the launchd disable flag"
assert_file_absent "$LSTATE/loaded" "job stays unloaded after install-while-paused"
assert_contains "$out" "kept the pause" "install while paused says it kept the pause"

# --- resume undoes everything: marker, disable flag, and loads the job --------
reset_calls
rc=0; out="$(run_sched resume)" || rc=$?
assert_rc 0 "$rc" "resume exits 0"
assert_file_absent "$PAUSE" "resume clears state/paused"
assert_file_absent "$LSTATE/disabled" "resume clears the launchd disable flag"
assert_file_present "$LSTATE/loaded" "resume loads the job"
order="$(grep -oE '^(enable|bootstrap)' "$CALLS" | tr '\n' ' ')"
assert_eq "enable bootstrap " "$order" "resume calls enable BEFORE bootstrap (launchd refuses a disabled bootstrap)"
assert_contains "$out" "resumed" "resume reports resumed"

# --- pause when bootout fails (job not loaded) still reports from durable state ---
rm -f "$LSTATE/loaded"
rc=0; out="$(run_sched pause)" || rc=$?
assert_rc 0 "$rc" "pause of an unloaded (but unpaused) job exits 0"
assert_file_present "$PAUSE" "pause of an unloaded job still writes the marker"
assert_contains "$out" "paused — durable" "pause of an unloaded job reports 'paused', not from bootout's failure" \
  "cmd_pause must not say 'already paused' just because bootout failed (issue #90)."
assert_not_contains "$out" "already paused" "pause of an unloaded job does not claim 'already paused'"

# A failing `launchctl disable` is reported, and the marker still holds the pause.
run_sched resume >/dev/null
touch "$LSTATE/fail-disable"
rc=0; out="$(run_sched pause)" || rc=$?
assert_rc 0 "$rc" "pause with a failing disable exits 0 (marker still holds)"
assert_file_present "$PAUSE" "pause with a failing disable still writes the marker"
assert_contains "$out" "'launchctl disable' failed" "a failing disable is reported, not hidden"
rm -f "$LSTATE/fail-disable"
run_sched resume >/dev/null

# --- status: not installed / installed-but-not-loaded ------------------------
rm -f "$LSTATE/loaded"
rc=0; out="$(run_sched status)" || rc=$?
assert_contains "$out" "installed but NOT loaded, and not paused" "status: installed+unloaded+unpaused is its own state"
mv "$PLIST_DST" "$PLIST_DST.bak"
rc=0; out="$(run_sched status)" || rc=$?
assert_contains "$out" "NOT installed" "status: no plist reports NOT installed"
mv "$PLIST_DST.bak" "$PLIST_DST"

# --- the in-flight guard is unchanged: refuse without --force, write nothing ---
printf -- '- #7 owner/repo issue-7 status dispatched pid %s\n' "$$" >"$SB/ledger.md"
rc=0; out="$(run_sched pause)" || rc=$?
assert_ne 0 "$rc" "pause with a live dispatch is refused"
assert_file_absent "$PAUSE" "a refused pause writes no marker"
rc=0; out="$(run_sched pause --force)" || rc=$?
assert_rc 0 "$rc" "pause --force with a live dispatch exits 0"
assert_file_present "$PAUSE" "pause --force writes the marker"
rm -f "$SB/ledger.md"

# --- schedule.sh run: the deliberate override passes --ignore-pause -----------
cat >"$SB/bin/run-cycle.sh" <<'SH'
#!/usr/bin/env bash
echo "RUN-CYCLE-ARGS: $*"
SH
chmod +x "$SB/bin/run-cycle.sh"
rc=0; out="$(run_sched run)" || rc=$?
assert_contains "$out" "RUN-CYCLE-ARGS: --no-arm --ignore-pause" "'schedule.sh run' passes --ignore-pause"
assert_contains "$out" "overriding for this one manual run" "'schedule.sh run' announces the override while paused"
rc=0; out="$(run_sched run --dry-run)" || rc=$?
assert_contains "$out" "--dry-run --no-arm --ignore-pause" "'schedule.sh run --dry-run' passes --ignore-pause"
assert_file_present "$PAUSE" "a manual run leaves the pause in place"

# --- run-cycle.sh: the pause gate --------------------------------------------
RC="$(new_sandbox)"
sandbox_copy_script "$RC" run-cycle
sandbox_copy_script "$RC" dispatch-common
SENT="$(sandbox_tmp)"
# Stub the two things run-cycle.sh would call: the cycle itself and the wake arm.
cat >"$RC/bin/orchestrator-cycle.sh" <<SH
#!/usr/bin/env bash
touch "$SENT/cycle-ran"
SH
cat >"$RC/bin/schedule.sh" <<SH
#!/usr/bin/env bash
touch "$SENT/arm-ran"
SH
chmod +x "$RC/bin/orchestrator-cycle.sh" "$RC/bin/schedule.sh"
echo live >"$RC/state/mode"
echo "2026-10-12 09:00:00" >"$RC/state/paused"
run_cycle() { JITTER_MAX_SECS=0 bash "$RC/bin/run-cycle.sh" "$@" 2>&1; }

rc=0; out="$(run_cycle --jitter)" || rc=$?
assert_rc 0 "$rc" "run-cycle.sh exits 0 when paused"
assert_contains "$(cat "$RC/logs/cycle.log")" "paused — not running" "run-cycle.sh logs 'paused — not running' to cycle.log"
assert_file_absent "$SENT/cycle-ran" "a paused fire does not run orchestrator-cycle.sh" \
  "run-cycle.sh must exit on state/paused before any dispatch (issue #90)."
assert_file_absent "$SENT/arm-ran" "a paused fire does not arm the next wake"
assert_not_contains "$(cat "$RC/logs/cycle.log")" "mode: LIVE" "a paused fire exits before resolving mode"

rc=0; out="$(run_cycle --no-arm --ignore-pause)" || rc=$?
assert_rc 0 "$rc" "run-cycle.sh --ignore-pause exits 0"
assert_file_present "$SENT/cycle-ran" "--ignore-pause runs the cycle despite the pause"
assert_contains "$(cat "$RC/logs/cycle.log")" "OVERRIDDEN for this manual run" "--ignore-pause logs the override"
assert_file_present "$RC/state/paused" "--ignore-pause leaves the marker in place"

rm -f "$SENT/cycle-ran" "$RC/state/paused"
rc=0; out="$(run_cycle --jitter)" || rc=$?
assert_rc 0 "$rc" "run-cycle.sh (unpaused) exits 0"
assert_file_present "$SENT/cycle-ran" "an unpaused fire runs the cycle"
assert_file_present "$SENT/arm-ran" "an unpaused scheduled fire arms the next wake"
