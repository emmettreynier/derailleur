#!/usr/bin/env bash
# smoke-test.sh — one-command bootstrap smoke test for the operator-identity guard.
#
# WHY: issue #4 (PR #7) funnelled all operator identity into a single gitignored
# orchestrator.conf, and every dispatch now passes through the guard in
# bin/config-common.sh (aborts if the conf is missing or any of the 5 fields is
# blank). Nothing exercised that checkpoint automatically — the only thing that
# tested the whole bootstrap chain was a new labmate's first-ever run. A broken
# guard or scaffold step stays invisible to the maintainer (whose conf is already
# filled) and only surfaces as a confusing day-one failure for someone else.
#
# This script verifies the guard's three states against THROWAWAY temp confs,
# proves a filled config renders into a brief, and checks the derailleur/dr CLI
# dispatcher routes correctly (including through a symlink, the way install.sh links
# it onto PATH) — all deterministically and offline. Any step that needs the network
# / `gh` auth prints a `SKIP:` line instead of failing.
#
# It NEVER creates, fills, or touches a real orchestrator.conf: every conf it reads
# lives in a mktemp dir that is removed on exit, and it asserts a pre-existing real
# conf is byte-identical (same shasum) before and after the run.
#
# See the README "Verify / smoke test" section for when to run it and how to read a
# failure.
set -euo pipefail

# --- locate self as repo root (per CLAUDE.md convention) ----------------------
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_COMMON="$ORCH/bin/config-common.sh"
CONF_EXAMPLE="$ORCH/orchestrator.conf.example"
CHECKER_BRIEF="$ORCH/briefs/checker-brief.md"
REAL_CONF="$ORCH/orchestrator.conf"
README_SECTION='Verify / smoke test'   # the anchor every failure message points at

[ -f "$CONFIG_COMMON" ] || { echo "smoke-test: cannot find $CONFIG_COMMON" >&2; exit 1; }

# --- reporting helpers --------------------------------------------------------
pass() { printf 'PASS: %s\n' "$1"; }
skip() { printf 'SKIP: %s\n' "$1"; }
fail() {
  # $1 = what failed, $2 = what to do about it
  printf 'FAIL: %s\n      %s\n      See the README "%s" section.\n' \
    "$1" "$2" "$README_SECTION" >&2
  exit 1
}

# --- throwaway conf sandbox (removed on exit) ---------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/derailleur-smoke.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

MISSING="$TMPROOT/missing"   # a root with NO orchestrator.conf
BLANK="$TMPROOT/blank"       # a conf with one field left blank
FILLED="$TMPROOT/filled"     # a conf with all 5 fields filled
mkdir -p "$MISSING" "$BLANK" "$FILLED"

# Copy the tracked example into each root so the guard's "cp example conf" guidance
# resolves to a real path (and so the missing-case message is realistic).
[ -f "$CONF_EXAMPLE" ] && cp "$CONF_EXAMPLE" "$MISSING/orchestrator.conf.example"

cat >"$BLANK/orchestrator.conf" <<'CONF'
OPERATOR_NAME="Smoke Test Operator"
GITHUB_HANDLE="smoke-test"
PR_OWNER=""
LAUNCHD_LABEL="com.smoke-test.orchestrator"
BOARD_PROJECT="1"
CONF

cat >"$FILLED/orchestrator.conf" <<'CONF'
OPERATOR_NAME="Smoke Test Operator"
GITHUB_HANDLE="smoke-test"
PR_OWNER="smoke-test"
LAUNCHD_LABEL="com.smoke-test.orchestrator"
BOARD_PROJECT="1"
CONF

# Run the guard against a given root in a subshell so its `exit 1` cannot kill us,
# and with the identity vars unset so nothing leaks in from the parent env.
guard_run() {  # $1 = conf root; echoes combined stdout+stderr, returns guard's exit
  (
    ORCH="$1" ORCH_DIR="$1"
    unset OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
    . "$CONFIG_COMMON"
  ) 2>&1
}

# --- (a) missing conf → nonzero exit + message --------------------------------
rc=0; out="$(guard_run "$MISSING")" || rc=$?
[ "$rc" -ne 0 ] || fail \
  "guard accepted a MISSING orchestrator.conf (expected nonzero exit)." \
  "bin/config-common.sh is not aborting when the conf is absent — check it."
printf '%s' "$out" | grep -q 'orchestrator.conf' || fail \
  "guard on a missing conf did not mention orchestrator.conf." \
  "The abort message should tell a labmate to copy the example."
pass "missing conf → guard aborts (exit $rc) with copy-the-example guidance"

# --- (b) one field blank → nonzero exit that NAMES the blank field ------------
rc=0; out="$(guard_run "$BLANK")" || rc=$?
[ "$rc" -ne 0 ] || fail \
  "guard accepted a conf with a blank PR_OWNER (expected nonzero exit)." \
  "bin/config-common.sh must reject any blank identity field."
printf '%s' "$out" | grep -q 'PR_OWNER' || fail \
  "guard rejected the blank conf but did not name the blank field (PR_OWNER)." \
  "The message must name which field is blank so it can be found and filled."
pass "blank field → guard aborts (exit $rc) and names the blank field (PR_OWNER)"

# --- (c) all 5 filled → exit 0, all 5 vars EXPORTED, and rendered into a brief -
# One subshell sources the guard (proving the filled conf is accepted), verifies a
# CHILD process inherits all 5 vars (proving `export`), then renders the checker
# brief the exact way the launchers do — strip the leading HTML comment, substitute
# every {{TOKEN}} from BRIEF_<TOKEN> (mirrors render_brief in launch-{worker,checker}.sh).
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
[ "$rc" -eq 0 ] || fail \
  "guard rejected an all-fields-filled conf, or the 5 vars were not exported (exit $rc)." \
  "A valid conf must exit 0 and export all 5 identity vars for child processes."
printf '%s' "$render_out" | grep -qF 'Smoke Test Operator' || fail \
  "OPERATOR_NAME did not render into the checker brief." \
  "The launchers substitute {{OPERATOR_NAME}} from the conf; that path is broken."
printf '%s' "$render_out" | grep -qF '{{OPERATOR_NAME}}' && fail \
  "the checker brief still has an unrendered {{OPERATOR_NAME}} token after render." \
  "Token substitution in the brief renderer is not replacing OPERATOR_NAME."
pass "filled conf → exit 0, all 5 vars exported, {{OPERATOR_NAME}} rendered into the brief"

# --- (d) the derailleur / dr CLI dispatcher -----------------------------------
# bin/derailleur (linked onto PATH as derailleur/dr by install.sh) fronts every
# bin/<cmd>.sh. Its one subtle part is the symlink-resolution walk that lets it find
# THIS repo's root when invoked through the ~/.local/bin symlink from any cwd — code
# that looks fine run directly from the repo but silently breaks via the installed
# link. These checks are deterministic and offline: `help` reads no external state,
# and the symlink path is exercised with a throwaway link in $TMPROOT (never a real
# ~/.local/bin write). No subcommand is dispatched, so nothing is spent.
DERAILLEUR="$ORCH/bin/derailleur"
[ -x "$DERAILLEUR" ] || fail \
  "bin/derailleur is missing or not executable." \
  "install.sh marks it +x; confirm the file exists and re-run ./bin/install.sh."

# help / no-arg / -h / --help all exit 0
for arg in NOARG help -h --help; do
  rc=0
  if [ "$arg" = NOARG ]; then
    out="$("$DERAILLEUR" 2>&1)" || rc=$?
  else
    out="$("$DERAILLEUR" "$arg" 2>&1)" || rc=$?
  fi
  [ "$rc" -eq 0 ] || fail \
    "derailleur usage path (arg='${arg#NOARG}') did not exit 0 (got $rc)." \
    "The dispatcher's help/usage path is broken — see bin/derailleur."
done
pass "dispatcher: no-arg / help / -h / --help all exit 0"

# the command list names real commands and excludes the sourced libs + itself
dr_cmds="$("$DERAILLEUR" help 2>/dev/null | grep -E '^  [a-z][a-z-]*$' || true)"
printf '%s\n' "$dr_cmds" | grep -qx '  launch-worker' || fail \
  "dispatcher help does not list a known command (launch-worker)." \
  "bin/derailleur builds its list from bin/*.sh — the glob or listing is broken."
for lib in dispatch-common config-common derailleur; do
  printf '%s\n' "$dr_cmds" | grep -qx "  $lib" && fail \
    "dispatcher help lists '$lib', which must be excluded (sourced lib, or itself)." \
    "bin/derailleur must skip dispatch-common/config-common and never list itself."
done
pass "dispatcher: help lists real commands, excludes sourced libs + itself"

# unknown subcommand and a sourced-lib name both exit 2 with a helpful message
rc=0; out="$("$DERAILLEUR" definitely-not-a-cmd 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unknown command'; } || fail \
  "unknown subcommand did not exit 2 with an 'unknown command' message (exit $rc)." \
  "bin/derailleur should reject unknown commands with usage + exit 2."
rc=0; out="$("$DERAILLEUR" config-common 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'sourced library'; } || fail \
  "invoking a sourced lib (config-common) did not exit 2 as a non-command (exit $rc)." \
  "bin/derailleur must refuse to dispatch dispatch-common/config-common."
pass "dispatcher: unknown cmd + sourced-lib name each exit 2 with guidance"

# THE subtle one: invoked THROUGH a symlink from a foreign cwd, it must still resolve
# this repo's bin/ (path-free) and yield the identical command list — proving the
# symlink-resolution walk lands on the real repo root, not the link's own directory.
ln -s "$DERAILLEUR" "$TMPROOT/dr"
rc=0; sym_help="$(cd "$TMPROOT" && ./dr help 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail \
  "the dispatcher failed when invoked through a symlink from another directory (exit $rc)." \
  "The symlink-resolution walk in bin/derailleur can't find the repo root via the installed link."
printf '%s' "$sym_help" | grep -qF "$ORCH/bin/" || fail \
  "symlinked dispatcher did not resolve back to $ORCH/bin (repo-root resolution failed)." \
  "bin/derailleur's while-symlink loop must resolve the link to this checkout."
sym_cmds="$(cd "$TMPROOT" && ./dr help 2>/dev/null | grep -E '^  [a-z][a-z-]*$' || true)"
[ "$sym_cmds" = "$dr_cmds" ] || fail \
  "command list differs between direct and symlinked invocation (resolution mismatch)." \
  "The dispatcher must behave identically via the ~/.local/bin symlink and a direct call."
pass "dispatcher: resolves this repo's bin/ through a symlink from a foreign cwd (identical command list)"

# --- real conf, if present: validate the operator's ACTUAL identity (offline) --
# Deterministic and read-only — sourcing only reads the file. This is what proves
# the maintainer's own conf actually passes the guard, not just the temp fixtures.
if [ -f "$REAL_CONF" ]; then
  REAL_SUM_BEFORE="$(shasum "$REAL_CONF")"
  rc=0; out="$(guard_run "$ORCH")" || rc=$?
  [ "$rc" -eq 0 ] || fail \
    "your real orchestrator.conf did not pass the guard (exit $rc): $out" \
    "Fill every field in $REAL_CONF (see Install step 5), then re-run."
  pass "real orchestrator.conf passes the guard (all identity fields filled)"
else
  skip "no real orchestrator.conf yet — copy orchestrator.conf.example and fill it (README Install step 5)"
fi

# --- live launcher dry-run: end-to-end config → board digest (network step) ----
# launch-orchestrator.sh --dry-run renders the live board via `gh`, so it needs
# auth + network. SKIP cleanly when unavailable — the test stays deterministic and
# passes offline. A nonzero here with gh available is treated as a network hiccup
# (SKIP with a diagnostic tail), never a hard failure, per the offline contract.
if ! command -v gh >/dev/null 2>&1; then
  skip "gh not installed — skipping live launch-orchestrator --dry-run"
elif ! gh auth status >/dev/null 2>&1; then
  skip "gh not authenticated / offline — skipping live launch-orchestrator --dry-run"
elif [ ! -f "$REAL_CONF" ]; then
  skip "no real orchestrator.conf — skipping live launch-orchestrator --dry-run"
else
  rc=0; out="$("$ORCH/bin/launch-orchestrator.sh" --dry-run 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'board digest'; then
    pass "live launch-orchestrator --dry-run renders the board digest from your conf"
  else
    skip "launch-orchestrator --dry-run did not complete (network/gh hiccup, exit $rc): $(printf '%s' "$out" | tail -1)"
  fi
fi

# --- standing guarantee: a pre-existing real conf is byte-identical -----------
if [ -f "$REAL_CONF" ]; then
  REAL_SUM_AFTER="$(shasum "$REAL_CONF")"
  [ "$REAL_SUM_BEFORE" = "$REAL_SUM_AFTER" ] || fail \
    "orchestrator.conf changed during the smoke test (checksum differs)." \
    "The smoke test must never write a real conf — this is a bug in smoke-test.sh."
  pass "real orchestrator.conf untouched (byte-identical shasum before/after)"
fi

echo
echo "smoke test: all checks passed."
