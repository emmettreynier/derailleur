#!/usr/bin/env bash
# config-common.sh — shared operator-identity loader, SOURCED (not executed) by the
# scripts that need to know who this instance runs as. The caller must already have
# set ORCH (or ORCH_DIR) to the repo root before sourcing.
#
# Reads $ORCH/orchestrator.conf (gitignored, per-operator; scaffolded from the tracked
# orchestrator.conf.example by install.sh). Exports OPERATOR_NAME / GITHUB_HANDLE /
# PR_OWNER / LAUNCHD_LABEL / BOARD_PROJECT. Fails loud if the conf is missing or any
# field is blank so no dispatch silently runs under someone else's identity.

_conf_root="${ORCH:-${ORCH_DIR:-}}"
_conf_file="$_conf_root/orchestrator.conf"
_conf_example="$_conf_root/orchestrator.conf.example"

if [ -f "$_conf_file" ]; then
  # shellcheck source=/dev/null
  . "$_conf_file"
fi

# Accumulate blanks into a space-separated string, NOT a bash array: an empty array
# expanded under `set -u` is a fatal "unbound variable" on the bash 3.2 macOS ships
# (see CLAUDE.md), and every sourcing script runs under `set -u`.
_conf_missing=""
[ -n "${OPERATOR_NAME:-}" ] || _conf_missing="$_conf_missing OPERATOR_NAME"
[ -n "${GITHUB_HANDLE:-}" ] || _conf_missing="$_conf_missing GITHUB_HANDLE"
[ -n "${PR_OWNER:-}" ]      || _conf_missing="$_conf_missing PR_OWNER"
[ -n "${LAUNCHD_LABEL:-}" ] || _conf_missing="$_conf_missing LAUNCHD_LABEL"
[ -n "${BOARD_PROJECT:-}" ] || _conf_missing="$_conf_missing BOARD_PROJECT"

if [ -n "$_conf_missing" ]; then
  {
    echo "config: missing operator identity —$_conf_missing"
    if [ -f "$_conf_file" ]; then
      echo "        Fill the blank field(s) in $_conf_file"
    else
      echo "        No orchestrator.conf found. Copy the example and fill it in:"
      echo "          cp \"$_conf_example\" \"$_conf_file\""
    fi
    echo "        Then confirm the bootstrap with 'dr test' — see the"
    echo "        README \"Verify / test suite\" section."
  } >&2
  exit 1
fi

export OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT

# --- optional per-operator settings ------------------------------------------
# ORCHESTRATOR_MODEL — the model the HEADLESS/autonomous orchestrator boots on
# (orchestrator-cycle.sh's `claude -p … --model`). Optional and deliberately NOT
# part of the required-identity guard above: its absence must never fail the guard
# or the test suite. Default `sonnet` when unset/blank so orchestrator-cycle.sh can
# resolve MODEL env → ORCHESTRATOR_MODEL (conf) → sonnet. Does NOT touch the
# interactive launcher (launch-orchestrator.sh stays on the session's model).
ORCHESTRATOR_MODEL="${ORCHESTRATOR_MODEL:-sonnet}"
export ORCHESTRATOR_MODEL

# --- per-repo autonomous-dispatch allow-list ---------------------------------
# state/scheduled-repos lists the slugs the AUTONOMOUS loop (orchestrator-cycle.sh,
# whether cron- or hand-triggered) is allowed to dispatch on — one slug per line,
# machine-local, gitignored with the rest of state/. Polarity is allow-list-WHEN-SET:
#   absent or empty  ⇒ ALL onboarded repos dispatch autonomously (backward-compatible)
#   non-empty        ⇒ ONLY the listed slugs dispatch autonomously
# It NEVER affects manual launch-worker.sh/launch-checker.sh or interactive /orchestrate
# — those operate on any onboarded repo regardless. This is the single reader so that
# orchestrator-cycle.sh, board-digest.sh, and schedule.sh can't drift apart.
SCHEDULED_REPOS_FILE="${SCHEDULED_REPOS_FILE:-$_conf_root/state/scheduled-repos}"
export SCHEDULED_REPOS_FILE

# scheduled_repos — echo the allow-list slugs, one per line, with comments (# …),
# leading/trailing whitespace, and blank lines stripped. Empty output ⇒ no allow-list
# in effect. Callers MUST branch on emptiness rather than expanding the result into a
# bash array unconditionally (an empty array under `set -u` is a fatal unbound-variable
# error on the bash 3.2 macOS ships — see CLAUDE.md). Ends with an explicit `return 0`
# so a caller invoking it bare isn't aborted when the file is absent / all-comment.
scheduled_repos() {
  [ -f "$SCHEDULED_REPOS_FILE" ] || return 0
  sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$SCHEDULED_REPOS_FILE" \
    | grep -v '^$' || true
  return 0
}
