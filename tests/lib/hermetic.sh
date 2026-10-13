#!/usr/bin/env bash
# tests/lib/hermetic.sh — the ONE list of operator/dispatch env vars the offline tier
# must never inherit (issue #101). SOURCED (never executed) by:
#   * bin/test.sh   — unsets them for every OFFLINE file it runs (the online tier keeps
#                     the caller's environment untouched: it reads the real conf on purpose);
#   * tests/lib/sandbox.sh — unsets them at source time, so a test run directly
#                     (`bash tests/offline/test-*.sh`) gets the same protection.
#
# WHY: bin/config-common.sh exports operator settings with the `${VAR:-default}` form,
# and the launchers export per-dispatch settings, so every dispatched worker/checker
# session inherits them. A sandboxed copy of a bin/ script then honours the HOST's
# value instead of the sandbox's own — e.g. SCHEDULED_REPOS_FILE pointing at the
# operator's real allow-list put `⏸ scheduler-paused` lines into a digest golden
# (PR #97 review). Tests that exercise one of these vars set it explicitly, after the
# unset.
#
# KEEP IN STEP: tests/offline/test-hermetic-env.sh derives the real exports from bin/
# (every `export NAME`, every `env "NAME=…"` a launcher passes to claude) and every
# key orchestrator.conf.example documents, and fails naming any that is missing here.
# Plain space-separated string, not an array (bash 3.2 + `set -u`, see CLAUDE.md).

HERMETIC_VARS="
OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT
ORCHESTRATOR_MODEL SCHEDULED_REPOS_FILE SCHEDULE_SLOTS
ORCH ORCH_DIR ORCH_MANIFEST ORCH_LOGS_DIR ORCH_PLAN_ONLY ORCH_DRY
DERAILLEUR_MACHINE_ENV QUARTO_CHROMIUM DIGEST_SLUG
CAP BUDGET MODEL LIVE WORKER_BUDGET CHECKER_BUDGET
CHECKER_LIMIT WORKER_LIMIT WORKER_WAIT_LIMIT
LEDGER DONE_DAYS BOARD_LIMIT OFFBOARD_LIMIT VERDICT_SWEEP_LIMIT VERDICT_ARCHIVE
TMUX_RUN_TAIL MERGEABLE_REPOLLS MERGEABLE_POLL_SLEEP MERGEABLE_POLL_CEILING
JITTER_MAX_SECS
"

# hermetic_unset — unset every HERMETIC_VARS name in the CURRENT shell. Ends with an
# explicit `return 0` so a caller invoking it bare under `set -e` is never aborted.
hermetic_unset() {
  local v
  for v in $HERMETIC_VARS; do
    unset "$v"
  done
  return 0
}
