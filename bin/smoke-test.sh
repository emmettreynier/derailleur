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
# This script verifies the guard's three states against THROWAWAY temp confs and
# proves a filled config renders into a brief — deterministically and offline. Any
# step that needs the network / `gh` auth prints a `SKIP:` line instead of failing.
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
