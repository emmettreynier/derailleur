#!/usr/bin/env bash
# test-dispatcher.sh (offline) — the derailleur/dr CLI dispatcher: help/usage,
# real-command listing, sourced-lib + unknown-command rejection, and (the subtle
# one) symlink resolution back to this checkout from a foreign cwd. Migrated from
# smoke-test.sh check (d). No subcommand is dispatched, so nothing is spent.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

DERAILLEUR="$REPO_ROOT/bin/derailleur"
assert_file_present "$DERAILLEUR" "bin/derailleur present" \
  "The CLI dispatcher is missing from bin/."
[ -x "$DERAILLEUR" ] || fail "bin/derailleur is not executable" \
  "install.sh marks it +x; confirm the file exists and re-run ./bin/install.sh."

# help / no-arg / -h / --help all exit 0
usage_ok=1
for arg in NOARG help -h --help; do
  rc=0
  if [ "$arg" = NOARG ]; then
    "$DERAILLEUR" >/dev/null 2>&1 || rc=$?
  else
    "$DERAILLEUR" "$arg" >/dev/null 2>&1 || rc=$?
  fi
  [ "$rc" -eq 0 ] || usage_ok=0
done
assert_eq 1 "$usage_ok" "dispatcher: no-arg / help / -h / --help all exit 0" \
  "The dispatcher's help/usage path is broken — see bin/derailleur."

# the command list names real commands and excludes the sourced libs + itself
dr_cmds="$("$DERAILLEUR" help 2>/dev/null | grep -E '^  [a-z][a-z-]*$' || true)"
assert_contains "$dr_cmds" "  launch-worker" "dispatcher help lists a known command (launch-worker)" \
  "bin/derailleur builds its list from bin/*.sh — the glob or listing is broken."
libs_leaked=0
for lib in dispatch-common config-common derailleur; do
  printf '%s\n' "$dr_cmds" | grep -qx "  $lib" && libs_leaked=1
done
assert_eq 0 "$libs_leaked" "dispatcher help excludes sourced libs + itself" \
  "bin/derailleur must skip dispatch-common/config-common and never list itself."

# unknown subcommand + sourced-lib name both exit 2 with a helpful message
rc=0; out="$("$DERAILLEUR" definitely-not-a-cmd 2>&1)" || rc=$?
assert_rc 2 "$rc" "unknown subcommand exits 2" \
  "bin/derailleur should reject unknown commands with usage + exit 2."
assert_contains "$out" "unknown command" "unknown subcommand prints an 'unknown command' message"
rc=0; out="$("$DERAILLEUR" config-common 2>&1)" || rc=$?
assert_rc 2 "$rc" "invoking a sourced lib (config-common) exits 2" \
  "bin/derailleur must refuse to dispatch dispatch-common/config-common."
assert_contains "$out" "sourced library" "sourced-lib rejection names it a 'sourced library'"

# THE subtle one: invoked THROUGH a symlink from a foreign cwd it must still resolve
# THIS repo's bin/ (path-free) and yield the identical command list.
LINKDIR="$(sandbox_tmp)"
ln -s "$DERAILLEUR" "$LINKDIR/dr"
rc=0; sym_help="$(cd "$LINKDIR" && ./dr help 2>&1)" || rc=$?
assert_rc 0 "$rc" "dispatcher works when invoked through a symlink from another dir" \
  "The symlink-resolution walk in bin/derailleur can't find the repo root via the installed link."
assert_contains "$sym_help" "$REPO_ROOT/bin/" "symlinked dispatcher resolves back to this checkout's bin/" \
  "bin/derailleur's while-symlink loop must resolve the link to this checkout."
sym_cmds="$(cd "$LINKDIR" && ./dr help 2>/dev/null | grep -E '^  [a-z][a-z-]*$' || true)"
assert_eq "$dr_cmds" "$sym_cmds" "command list identical via direct + symlinked invocation" \
  "The dispatcher must behave identically via the ~/.local/bin symlink and a direct call."
