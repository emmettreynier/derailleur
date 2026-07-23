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
# proves a filled config renders into a brief, checks the derailleur/dr CLI
# dispatcher routes correctly (including through a symlink, the way install.sh links
# it onto PATH), and unit-tests watch-dispatch.sh's terminal-state classification
# against a throwaway ledger/verdict fixture — all deterministically and offline.
# Any step that needs the network / `gh` auth prints a `SKIP:` line instead of failing.
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

# --- (e) watch-dispatch.sh terminal-state detection ---------------------------
# watch-dispatch.sh is pure, deterministic, offline local-signal logic — the ideal
# unit test. Copy the real script into a throwaway ORCH (its own bin/ + ledger.md +
# logs/) so its `cd dirname/..` resolution lands in the sandbox, seed ledger/verdict
# fixtures covering every branch, and assert `--dry-run`'s one-shot classification.
# No loop, no sleep, no network — nothing dispatched, nothing spent.
WATCH="$ORCH/bin/watch-dispatch.sh"
[ -x "$WATCH" ] || fail \
  "bin/watch-dispatch.sh is missing or not executable." \
  "install.sh's bin/*.sh chmod covers it; confirm the file exists and re-run ./bin/install.sh."

WROOT="$TMPROOT/watch"; mkdir -p "$WROOT/bin" "$WROOT/logs"
cp "$WATCH" "$WROOT/bin/watch-dispatch.sh"
# Fixtures ($$ = this live shell): a done worker (status flip); a checker still
# 'dispatched' but WITH a written verdict (verdict must win over status); a worker
# whose pid is dead while status never finalized (=> unknown, the silence-is-not-
# success guard); and a genuinely live dispatched worker (=> pending, must NOT be
# called terminal).
cat >"$WROOT/ledger.md" <<LEDGER
- #10 | owner/demo | issue-10 | $WROOT/logs/demo-issue-10.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status done
- check pr#20 | owner/demo | issue-10 | $WROOT/logs/demo-pr-20.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
- #30 | owner/demo | issue-30 | $WROOT/logs/demo-issue-30.log | pid 99999999 | dispatched 2026-01-01T00:00:00Z | status dispatched
- #40 | owner/demo | issue-40 | $WROOT/logs/demo-issue-40.log | pid $$ | dispatched 2026-01-01T00:00:00Z | status dispatched
LEDGER
printf '{"verdict":"checked-pass"}\n' >"$WROOT/logs/demo-pr-20-verdict.json"

rc=0
wd_out="$("$WROOT/bin/watch-dispatch.sh" --dry-run demo#10 demo#pr20 demo#30 demo#40 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail \
  "watch-dispatch.sh --dry-run exited nonzero ($rc) on a valid fixture: $(printf '%s' "$wd_out" | tail -1)" \
  "The script should classify each item and exit 0 in --dry-run; see bin/watch-dispatch.sh."
printf '%s\n' "$wd_out" | grep -qE 'demo#10 \(worker\) -> done' || fail \
  "watch-dispatch did not classify a status=done worker as 'done'." \
  "Ledger status-flip detection is broken in bin/watch-dispatch.sh."
printf '%s\n' "$wd_out" | grep -qE 'demo#pr20 \(checker\) -> checked-pass' || fail \
  "watch-dispatch did not read the checker verdict JSON (expected 'checked-pass')." \
  "Verdict-file detection (jq .verdict) is broken, or it lost to the still-dispatched status."
printf '%s\n' "$wd_out" | grep -qE 'demo#30 \(worker\) -> unknown' || fail \
  "watch-dispatch did not report a dead-but-unfinalized pid as 'unknown'." \
  "The silence-is-not-success guard (pid liveness) is broken in bin/watch-dispatch.sh."
printf '%s\n' "$wd_out" | grep -qE 'demo#40 \(worker\) -> pending' || fail \
  "watch-dispatch flagged a live, still-dispatched worker as terminal (expected 'pending')." \
  "A running dispatch must NOT be classified terminal — check the status/pid logic."
pass "watch-dispatch: done / verdict-wins / dead-pid=unknown / live=pending all classify correctly"

rc=0; "$WROOT/bin/watch-dispatch.sh" --dry-run bogusitem >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail \
  "watch-dispatch accepted a malformed item token (expected exit 2, got $rc)." \
  "Item parsing must reject anything not <slug>#<issue> / <slug>#pr<n>."
rc=0; "$WROOT/bin/watch-dispatch.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail \
  "watch-dispatch with no items did not exit 2 (got $rc)." \
  "The script must require at least one item to watch."
pass "watch-dispatch: malformed item + no-args each exit 2"

# --- (f) tmux-run.sh: name/log derivation + the atomic-create mutex -----------
# tmux-run.sh is the worker's detached long-running-job wrapper (issue #22): it derives
# a canonical session name + durable log from a project manifest and does an atomic
# `tmux new-session` that doubles as a cross-worker mutex. Test it in a SANDBOX ORCH
# (copy the script into $TRROOT/bin so its `cd dirname/..` root resolution lands in the
# sandbox, seed a throwaway manifest + temp data_root) so it touches no real project.
# The dry-run half is deterministic + offline; the live mutex half needs tmux and SKIPs
# cleanly when it's absent (mirrors the offline contract). Nothing is spent.
TMUXRUN="$ORCH/bin/tmux-run.sh"
[ -x "$TMUXRUN" ] || fail \
  "bin/tmux-run.sh is missing or not executable." \
  "install.sh's bin/*.sh chmod covers it; confirm the file exists and re-run ./bin/install.sh."

TRROOT="$TMPROOT/tmuxrun"; mkdir -p "$TRROOT/bin" "$TRROOT/projects"
cp "$TMUXRUN" "$TRROOT/bin/tmux-run.sh"
TR_DATA="$TRROOT/data"
TR_NAME="derail-owner-demo-repo-7"   # derived from repo owner/demo-repo + issue 7
cat >"$TRROOT/projects/zz-smoke.yml" <<YML
repo: owner/demo-repo
data_root: $TR_DATA
YML

# dry-run: derives derail-owner-demo-repo-7 + a log under <data_root>/logs, creates nothing.
rc=0; dr_out="$("$TRROOT/bin/tmux-run.sh" zz-smoke 7 --dry-run 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail \
  "tmux-run.sh --dry-run exited nonzero ($rc): $(printf '%s' "$dr_out" | tail -1)" \
  "The wrapper should derive the name/log and exit 0 in --dry-run; see bin/tmux-run.sh."
printf '%s' "$dr_out" | grep -qF "$TR_NAME" || fail \
  "tmux-run --dry-run did not derive the canonical name $TR_NAME." \
  "Name derivation (repo with /->-, + issue) is broken in bin/tmux-run.sh."
printf '%s' "$dr_out" | grep -qF "$TR_DATA/logs/$TR_NAME.log" || fail \
  "tmux-run --dry-run did not compute the durable log under <data_root>/logs." \
  "Log-path derivation is broken in bin/tmux-run.sh."
[ ! -d "$TR_DATA/logs" ] || fail \
  "tmux-run --dry-run created the log dir (it must create nothing)." \
  "The --dry-run branch must precede any mkdir in bin/tmux-run.sh."
pass "tmux-run: --dry-run derives canonical name + <data_root>/logs path, creates nothing"

# live mutex walk — needs tmux; SKIP cleanly (never fail) when it's unavailable.
if ! command -v tmux >/dev/null 2>&1; then
  skip "tmux not installed — skipping tmux-run live mutex case"
else
  tmux kill-session -t "$TR_NAME" 2>/dev/null || true   # clean slate (a prior abort could leave it)
  # the command emits output immediately (echo) so the tee'd log is non-empty at once
  # first call → created
  rc=0; a_out="$("$TRROOT/bin/tmux-run.sh" zz-smoke 7 -- sh -c 'echo started; sleep 60' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$a_out" | grep -q 'status=created'; then
    tmux kill-session -t "$TR_NAME" 2>/dev/null || true
    fail "tmux-run first call did not report status=created (exit $rc): $(printf '%s' "$a_out" | head -1)" \
         "Atomic create path is broken in bin/tmux-run.sh."
  fi
  # second identical call → exists-alive + log tail; must NOT spawn a duplicate
  rc=0; b_out="$("$TRROOT/bin/tmux-run.sh" zz-smoke 7 -- sh -c 'echo started; sleep 60' 2>&1)" || rc=$?
  dup="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cx "$TR_NAME" || true)"
  logsz=0; [ -s "$TR_DATA/logs/$TR_NAME.log" ] && logsz=1
  tmux kill-session -t "$TR_NAME" 2>/dev/null || true   # teardown before asserting so nothing leaks
  { [ "$rc" -eq 0 ] && printf '%s' "$b_out" | grep -q 'status=exists-alive'; } || fail \
    "tmux-run second call did not report status=exists-alive (exit $rc): $(printf '%s' "$b_out" | head -1)" \
    "The mutex/reconcile classification is broken in bin/tmux-run.sh."
  [ "$dup" = 1 ] || fail \
    "tmux-run spawned a duplicate session (found $dup named $TR_NAME; the atomic-create mutex is broken)." \
    "A colliding create must report the existing session, never create a second — see bin/tmux-run.sh."
  [ "$logsz" = 1 ] || fail \
    "tmux-run did not write a non-empty durable log at $TR_DATA/logs/$TR_NAME.log." \
    "The tee'd log path (2>&1 | tee <log>) is broken in bin/tmux-run.sh."
  pass "tmux-run: atomic mutex — created then exists-alive, exactly one session, durable log written"
fi

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
