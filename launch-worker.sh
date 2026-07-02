#!/usr/bin/env bash
# launch-worker.sh — dispatch ONE guarded headless worker for a GitHub issue.
#
# This is the single entry point for spawning workers. The orchestrator must NEVER
# hand-roll a `claude` invocation: routing every dispatch through here means the
# raw-data guard, safety flags, and budget cap are wired in *by construction*, not
# by anyone remembering to add them. (See design.md — Safety Layer 2.)
#
# Every dispatch is a FRESH session (no resume mode): the worker re-derives state
# from the issue + any existing PR. If the branch already exists (e.g. addressing
# review feedback) the worktree is based on it; otherwise on the up-to-date default
# branch. Project specifics (raw/output paths, repo) come from the manifest, so the
# protocol brief stays project-agnostic.
#
# Usage:
#   launch-worker.sh <repo-slug> <issue#> [--dry-run] [--foreground] [--budget USD] [--fallback MODEL]
#     <repo-slug>  matches projects/<repo-slug>.yml   (e.g. solar-income)
#     --dry-run    print the fully-assembled, guarded command and exit (spends nothing)
#     --foreground run in the foreground (supervised); default detaches
#
set -euo pipefail

# --- locate self + hub repo ---------------------------------------------------
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../orchestrator
HOOK="$ORCH/host/hooks/raw-data-guard.py"
STOP_HOOK="$ORCH/host/hooks/worker-stop-guard.sh"
TEMPLATE="$ORCH/templates/pr-results-summary.md"
BRIEF_FILE="$ORCH/worker-brief.md"
source "$ORCH/dispatch-common.sh"   # classify_result / finalize_dispatch

# Render a brief .md file into a system-prompt string: strip the leading HTML-comment
# header, then substitute every {{TOKEN}} from the matching BRIEF_<TOKEN> env var.
# Keeps role/protocol briefs in editable .md files instead of buried in heredocs.
render_brief() {
  python3 - "$1" <<'PY'
import os, re, sys
text = re.sub(r'^<!--.*?-->\n', '', open(sys.argv[1]).read(), count=1, flags=re.S)
print(re.sub(r'{{(\w+)}}',
             lambda m: os.environ.get('BRIEF_' + m.group(1), m.group(0)),
             text), end='')
PY
}

# --- args ---------------------------------------------------------------------
DRY=0
FG=0
# Budget precedence: explicit --budget arg > $WORKER_BUDGET env > default. The env
# var lets the orchestrator cycle (or a direct caller) raise the ceiling without
# editing this file; the arg still wins for a one-off override.
BUDGET="${WORKER_BUDGET:-10.00}"
FALLBACK="claude-sonnet-4-6"
REPO_SLUG="${1:?usage: launch-worker.sh <repo-slug> <issue#> [--dry-run]}"
ISSUE="${2:?usage: launch-worker.sh <repo-slug> <issue#> [--dry-run]}"
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY=1 ;;
    --foreground) FG=1 ;;
    --budget)   BUDGET="$2"; shift ;;
    --fallback) FALLBACK="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done

MANIFEST="$ORCH/projects/$REPO_SLUG.yml"
[ -f "$MANIFEST" ]   || { echo "no manifest for '$REPO_SLUG': $MANIFEST" >&2; exit 1; }
[ -x "$HOOK" ]       || { echo "deny-hook missing/not executable: $HOOK" >&2; exit 1; }
[ -x "$STOP_HOOK" ]  || { echo "stop-hook missing/not executable: $STOP_HOOK" >&2; exit 1; }
[ -f "$BRIEF_FILE" ] || { echo "worker brief missing: $BRIEF_FILE" >&2; exit 1; }

# --- manifest readers ---------------------------------------------------------
yml() { sed -nE "s/^$1:[[:space:]]*(.+)/\1/p" "$MANIFEST" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
expand() { eval echo "$1"; }   # ~ and $VAR expansion for path fields
# Render a yaml list field as a comma-separated string (for the brief).
yml_list() { python3 - "$MANIFEST" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(rf'^{sys.argv[2]}:\s*(?:#.*)?\n((?:[ \t]+-.*\n?)+)', text, re.M)
out = []
if m:
    for line in m.group(1).splitlines():
        mm = re.match(r'\s*-\s*(.+?)\s*(?:#.*)?$', line)
        if mm and mm.group(1):
            out.append(mm.group(1).strip().strip('"').strip("'"))
print(', '.join(out))
PY
}

REPO="$(yml repo)"
WORKING_CLONE="$(expand "$(yml working_clone)")"
WORKTREES_DIR="$(expand "$(yml worktrees_dir)")"
RAW_RESOLVED="$(expand "$(yml raw_resolved)")"
OUTPUT_PATHS="$(yml_list output_paths)"

BRANCH="issue-$ISSUE"
WORKTREE="$WORKTREES_DIR/$BRANCH"
LOG="$ORCH/logs/${REPO_SLUG}-issue-${ISSUE}.log"
LEDGER="$ORCH/ledger.md"
RESULTS_SUMMARY="$(cat "$TEMPLATE" 2>/dev/null || echo '(results-summary template not found)')"

# --- the guards: worker settings registering both hooks ----------------------
# PreToolUse → raw-data deny-hook (Layer 2). Stop → exit-contract guard: refuse to
# end until the worker left a trail (a PR, or a needs-input escalation). ISSUE/REPO
# are baked into the Stop command so the hook needs no manifest parsing; one firm
# nudge only (the hook honors stop_hook_active to avoid loops).
# Compact single-line JSON so it passes cleanly as one --settings argument.
SETTINGS_JSON="$(HOOK="$HOOK" STOP_HOOK="$STOP_HOOK" ISSUE="$ISSUE" REPO="$REPO" python3 - <<'PY'
import json, os
print(json.dumps({"hooks": {
    "PreToolUse": [
        {"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
         "hooks": [{"type": "command", "command": os.environ["HOOK"]}]}
    ],
    "Stop": [
        {"hooks": [{"type": "command",
                    "command": "%s %s %s" % (os.environ["STOP_HOOK"],
                                             os.environ["ISSUE"], os.environ["REPO"])}]}
    ],
}}))
PY
)"

# --- worker protocol brief (system prompt; project-agnostic, manifest-filled) --
BRIEF="$(BRIEF_ISSUE="$ISSUE" BRIEF_REPO="$REPO" BRIEF_WORKTREE="$WORKTREE" \
         BRIEF_RAW_RESOLVED="$RAW_RESOLVED" BRIEF_OUTPUT_PATHS="$OUTPUT_PATHS" \
         BRIEF_RESULTS_SUMMARY="$RESULTS_SUMMARY" \
         render_brief "$BRIEF_FILE")"

TASK="Work issue #$ISSUE in $REPO. Read it with \`gh issue view $ISSUE -R $REPO --comments\`; if a PR for this branch already exists, read it and its review comments too. Then do the work and open or update the PR."

# --- assemble the (guarded) invocation ----------------------------------------
# env-prefix exports ORCH_MANIFEST so the deny-hook subprocess can read raw_paths.
build_cmd() {
  CMD=( env "ORCH_MANIFEST=$MANIFEST" claude -p "$TASK"
        --permission-mode bypassPermissions
        --settings "$SETTINGS_JSON"
        --add-dir "$WORKTREE"
        --add-dir "$RAW_RESOLVED"
        --max-budget-usd "$BUDGET"
        --append-system-prompt "$BRIEF"
        --fallback-model "$FALLBACK"
        --output-format json )
}
build_cmd

# --- dry run: show resolved config + command, spend nothing -------------------
if [ "$DRY" = 1 ]; then
  cat <<INFO
# DRY RUN — guarded worker for $REPO issue #$ISSUE
#   manifest      : $MANIFEST
#   working clone : $WORKING_CLONE
#   worktree      : $WORKTREE   (branch: $BRANCH)
#   raw (RO)      : $RAW_RESOLVED   <- --add-dir + deny-hook protected
#   outputs       : $OUTPUT_PATHS
#   deny-hook     : $HOOK   <- injected via --settings (PreToolUse)
#   stop-hook     : $STOP_HOOK $ISSUE $REPO   <- injected via --settings (Stop): exit-contract guard
#   budget cap    : \$$BUDGET   fallback: $FALLBACK
#   log           : $LOG
#
# Assembled command:
INFO
  printf '  %q' "${CMD[@]}"; echo
  exit 0
fi

# --- real dispatch ------------------------------------------------------------
mkdir -p "$WORKTREES_DIR" "$ORCH/logs"
git -C "$WORKING_CLONE" fetch -q origin || true
BASE_REF="$(git -C "$WORKING_CLONE" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"

# Worktree (idempotent): reuse if present; else base on the remote branch when it
# exists (review feedback), otherwise on the up-to-date default branch (fresh start).
if [ ! -d "$WORKTREE" ]; then
  if git -C "$WORKING_CLONE" show-ref -q --verify "refs/remotes/origin/$BRANCH"; then
    git -C "$WORKING_CLONE" worktree add "$WORKTREE" -B "$BRANCH" "origin/$BRANCH"
  else
    git -C "$WORKING_CLONE" worktree add -b "$BRANCH" "$WORKTREE" "$BASE_REF"
  fi
fi

# Worktree data bootstrap: data/ is machine-local (gitignored), so provide the
# read-only raw symlink + a writable results dir for the worker to use.
if [ -n "$RAW_RESOLVED" ]; then
  mkdir -p "$WORKTREE/data/results"
  ln -sfn "$RAW_RESOLVED" "$WORKTREE/data/raw"
fi

# Ledger: local execution state GitHub doesn't record. `pid` lets the digest
# tell a live worker from a crashed one; `status` (dispatched/done/failed) is
# what the digest keys on for staleness and Phase 4 will flip on completion.
write_ledger() {  # $1 = pid, $2 = status
  printf -- '- #%s | %s | %s | %s | pid %s | dispatched %s | status %s\n' \
    "$ISSUE" "$REPO" "$BRANCH" "$LOG" "$1" "$(date -u +%FT%TZ)" "$2" >> "$LEDGER"
}

echo "Dispatching worker for $REPO #$ISSUE → $WORKTREE (log: $LOG)"
if [ "$FG" = 1 ]; then
  # Supervised: run in the foreground, tee the log. pid "-" (you're watching it).
  write_ledger "-" "dispatched"
  # `|| true`: claude exits NONZERO on an interrupted run (budget cap / rate limit /
  # error). Under `set -e` that would abort before finalize_dispatch — which exists
  # precisely to record those interruptions — so the cutoff would go unrecorded.
  ( cd "$WORKTREE" && "${CMD[@]}" ) 2>&1 | tee "$LOG" || true
  finalize_dispatch "$LOG" "$LEDGER" "-" "$WORKTREE" "worker"
else
  # Detached + ISOLATED: run in its OWN session so a process-group signal sent when the
  # dispatching orchestrator session tears down can't reap the worker (the 0-byte-log
  # deaths of 2026-06-22). run_in_new_session execs the guarded command via a python
  # os.setsid() shim, runs finalize_dispatch when it exits (so an interrupted run is
  # recorded, not left looking dispatched), and preserves the pid so $! is the session
  # leader. Background it here and capture $! for the ledger.
  run_in_new_session "$LOG" "$LEDGER" "$WORKTREE" "worker" "" -- "${CMD[@]}" &
  WORKER_PID=$!
  disown 2>/dev/null || true
  write_ledger "$WORKER_PID" "dispatched"
  echo "  pid $WORKER_PID (detached, own session)"
fi
