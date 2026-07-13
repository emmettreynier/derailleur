#!/usr/bin/env bash
# config-common.sh — shared operator-identity loader, SOURCED (not executed) by the
# scripts that need to know who this instance runs as. The caller must already have
# set ORCH (or ORCH_DIR) to the repo root before sourcing.
#
# Reads $ORCH/orchestrator.conf (gitignored, per-operator; scaffolded from the tracked
# orchestrator.conf.example by install.sh). Exports OPERATOR_NAME / GITHUB_HANDLE /
# PR_OWNER / LAUNCHD_LABEL. Fails loud if the conf is missing or any field is blank so
# no dispatch silently runs under someone else's identity.

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

if [ -n "$_conf_missing" ]; then
  {
    echo "config: missing operator identity —$_conf_missing"
    if [ -f "$_conf_file" ]; then
      echo "        Fill the blank field(s) in $_conf_file"
    else
      echo "        No orchestrator.conf found. Copy the example and fill it in:"
      echo "          cp \"$_conf_example\" \"$_conf_file\""
    fi
  } >&2
  exit 1
fi

export OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL
