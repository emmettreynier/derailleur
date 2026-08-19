#!/usr/bin/env bash
# launch-checker.sh — dispatch ONE guarded headless CHECKER for a ready PR.
#
# Mirrors launch-worker.sh, but the checker VERIFIES rather than works: it boots
# with NO Edit/Write tools (it literally cannot modify code) and the launcher
# records a mutation baseline before/after as belt-and-suspenders. It reads the
# PR's issue acceptance criteria, runs/inspects the outputs, emits a structured
# verdict JSON, posts a PR review, and routes (approve / request-changes+resume /
# needs-input). See design.md — "Checkers".
#
# Triggers only on a READY (un-drafted) PR — that is the deliberate "check me now"
# signal. A draft PR is still the worker's court; this refuses to run on one.
#
# Usage:
#   launch-checker.sh <repo-slug> <pr#> [--dry-run] [--foreground] [--budget USD] [--fallback MODEL]
#     <repo-slug>  matches projects/<repo-slug>.yml   (e.g. solar-income)
#     --dry-run    print the fully-assembled command and exit (spends nothing)
#     --foreground run in the foreground (supervised); default detaches
set -euo pipefail

# --- locate self + hub repo ---------------------------------------------------
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../orchestrator
source "$ORCH/bin/config-common.sh"   # OPERATOR_NAME (rendered into the checker brief)
HOOK="$ORCH/host/hooks/raw-data-guard.py"
BRIEF_FILE="$ORCH/briefs/checker-brief.md"
source "$ORCH/bin/dispatch-common.sh"   # classify_result / finalize_dispatch

# Render a brief .md file into a system-prompt string: strip the leading HTML-comment
# header, then substitute every {{TOKEN}} from the matching BRIEF_<TOKEN> env var.
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
BUDGET="${CHECKER_BUDGET:-3.00}"   # substantive verification (re-running/inspecting real outputs) is opus-heavy; --budget arg > $CHECKER_BUDGET env > default
FALLBACK="claude-sonnet-4-6"
REPO_SLUG="${1:?usage: launch-checker.sh <repo-slug> <pr#> [--dry-run]}"
PR="${2:?usage: launch-checker.sh <repo-slug> <pr#> [--dry-run]}"
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

# Mechanical plan-only gate (mirrors launch-worker.sh): a plan-only orchestrator cycle
# exports ORCH_PLAN_ONLY=1, inherited by this script when the cycle (or the headless
# orchestrator) runs it. Force --dry-run so a plan-only cycle can never dispatch a real,
# spending checker — the gate is by construction, not advice to a model (issue #18).
if [ "${ORCH_PLAN_ONLY:-0}" = 1 ] && [ "$DRY" = 0 ]; then
  echo "⚠ ORCH_PLAN_ONLY set — forcing --dry-run (a plan-only cycle cannot dispatch for real)." >&2
  DRY=1
fi

MANIFEST="$ORCH/projects/$REPO_SLUG.yml"
[ -f "$MANIFEST" ]   || { echo "no manifest for '$REPO_SLUG': $MANIFEST" >&2; exit 1; }
[ -x "$HOOK" ]       || { echo "deny-hook missing/not executable: $HOOK" >&2; exit 1; }
[ -f "$BRIEF_FILE" ] || { echo "checker brief missing: $BRIEF_FILE" >&2; exit 1; }

# --- manifest readers ---------------------------------------------------------
yml() { sed -nE "s/^$1:[[:space:]]*(.+)/\1/p" "$MANIFEST" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
expand() { eval echo "$1"; }   # ~ and $VAR expansion for path fields
# Render a yaml list field as a comma-separated string (mirrors launch-worker.sh).
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
DERIVED_RESOLVED="$(expand "$(yml derived_resolved)")"   # optional; unset = byte-identical to pre-#38 behavior
DROPBOX_PROJ="$(expand "$(yml dropbox_proj)")"   # optional; empty = let the repo's setup-symlinks.sh default it
CRITICAL_PATHS="$(yml_list critical_paths)"      # optional; comma-separated worktree-relative gate paths (issue #43)

# Same branch-(a) caveat as the worker (see launch-worker.sh). Note the label says WRITABLE
# rather than RO: the checker drops Edit/Write and does not mutate BY POLICY, but it keeps
# Bash and runs the same deny-hook with the same manifest, so the derived carveout permits a
# shell redirect there exactly as it does under data/results. Claiming RO would describe a
# guarantee the guard does not make; report_mutation is what actually catches mutation, and
# its baseline covers the worktree.
DERIVED_NOTE=""
if [ -n "$DERIVED_RESOLVED" ]; then
  if [ -x "$WORKING_CLONE/setup-symlinks.sh" ]; then
    DERIVED_NOTE="IGNORED here — this repo ships setup-symlinks.sh, which owns data/derived"
  else
    DERIVED_NOTE="shared tree the worker wrote; WRITABLE via the guard (checker does not mutate by policy)"
  fi
fi

# --- resolve the PR: branch, the issue it closes, and ready/draft state -------
PR_JSON="$(gh pr view "$PR" -R "$REPO" --json isDraft,headRefName,closingIssuesReferences,state 2>/dev/null)" \
  || { echo "could not read PR #$PR in $REPO" >&2; exit 1; }
PR_STATE="$(echo "$PR_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')"
IS_DRAFT="$(echo "$PR_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["isDraft"])')"
BRANCH="$(echo "$PR_JSON"   | python3 -c 'import sys,json;print(json.load(sys.stdin)["headRefName"])')"
ISSUE="$(echo "$PR_JSON"    | python3 -c 'import sys,json
refs=json.load(sys.stdin).get("closingIssuesReferences") or []
print(refs[0]["number"] if refs else "")')"

[ "$PR_STATE" = "OPEN" ] || { echo "PR #$PR is $PR_STATE, not OPEN — nothing to check." >&2; exit 1; }
[ "$IS_DRAFT" = "True" ] && { echo "PR #$PR is a DRAFT — still the worker's court; checker runs on ready PRs only." >&2; exit 1; }
[ -n "$ISSUE" ] || { echo "PR #$PR closes no issue (no acceptance criteria to verify against) — refusing to check." >&2; exit 1; }

WORKTREE="$WORKTREES_DIR/$BRANCH"
LOG="$ORCH/logs/${REPO_SLUG}-pr-${PR}.log"
VERDICT_FILE="$ORCH/logs/${REPO_SLUG}-pr-${PR}-verdict.json"
LEDGER="$ORCH/ledger.md"

# --- the guard: register the deny-hook (belt-and-suspenders; checker has no Edit/Write) -
SETTINGS_JSON="$(HOOK="$HOOK" python3 - <<'PY'
import json, os
print(json.dumps({"hooks": {"PreToolUse": [
    {"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
     "hooks": [{"type": "command", "command": os.environ["HOOK"]}]}
]}}))
PY
)"

# --- checker protocol brief (system prompt; manifest/PR-filled) ----------------
BRIEF="$(BRIEF_PR="$PR" BRIEF_REPO="$REPO" BRIEF_ISSUE="$ISSUE" \
         BRIEF_WORKTREE="$WORKTREE" BRIEF_VERDICT_FILE="$VERDICT_FILE" \
         BRIEF_OPERATOR_NAME="$OPERATOR_NAME" \
         render_brief "$BRIEF_FILE")"

TASK="Check ready PR #$PR in $REPO (closes issue #$ISSUE). Verify it against the issue's acceptance criteria, emit the verdict JSON to $VERDICT_FILE, post your PR review, and route per your brief."

# --- assemble the (guarded, no-mutate) invocation -----------------------------
# Same guard env + deny-hook as a worker, PLUS --disallowedTools strips every
# code-mutating tool: the checker can Read + run Bash (tests/gh) but cannot Edit/Write.
# That same list denies Agent — delegation escapes the protocol layer: a subagent gets
# no brief (no verdict-JSON contract, no routing vocabulary), is not bound by the
# session's Stop-hook exit contract (it fires SubagentStop), and spends against this
# session's --max-budget-usd. Blanket deny, not an enumerated one: "deny all but
# Explore" is not expressible, and a named list fails OPEN the next time an agent
# lands in ~/.claude/agents/. Keep it in this one flag — do not add a second
# --disallowedTools, and do not "simplify" Agent out of it. (issue #45)
build_cmd() {
  # ORCH_LOGS_DIR + its --add-dir let the checker write its verdict JSON to the
  # orchestrator's own logs/ (runtime state, never project raw data) even when a
  # self-hosting manifest's raw_resolved blankets the whole live clone. The deny-hook
  # treats ORCH_LOGS_DIR as an always-writable carveout; --add-dir grants Layer-1 access.
  # The checker mutates no files but DOES re-run pipeline stages, so it must be able to
  # READ the shared derived tree the worker wrote. Appended only when the manifest sets
  # derived_resolved, keeping the command byte-identical for manifests that don't (#38).
  ADD_DIRS=( --add-dir "$WORKTREE" --add-dir "$RAW_RESOLVED" --add-dir "$ORCH/logs" )
  [ -n "$DERIVED_RESOLVED" ] && ADD_DIRS+=( --add-dir "$DERIVED_RESOLVED" )
  CMD=( env "ORCH_MANIFEST=$MANIFEST" "ORCH_LOGS_DIR=$ORCH/logs" claude -p "$TASK"
        --permission-mode bypassPermissions
        --settings "$SETTINGS_JSON"
        "${ADD_DIRS[@]}"
        --disallowedTools Edit Write NotebookEdit Agent
        --max-budget-usd "$BUDGET"
        --append-system-prompt "$BRIEF"
        --fallback-model "$FALLBACK"
        --output-format json )
}
build_cmd

# --- dry run: show resolved config + command, spend nothing -------------------
if [ "$DRY" = 1 ]; then
  cat <<INFO
# DRY RUN — guarded checker for $REPO PR #$PR (closes #$ISSUE)
#   manifest      : $MANIFEST
#   working clone : $WORKING_CLONE
#   worktree      : $WORKTREE   (branch: $BRANCH)
#   raw (RO)      : $RAW_RESOLVED   <- --add-dir + deny-hook protected
INFO
  # Printed only when configured — see launch-worker.sh for the byte-identical rationale.
  [ -n "$DERIVED_RESOLVED" ] && cat <<INFO
#   derived       : $DERIVED_RESOLVED   <- $DERIVED_NOTE
INFO
  cat <<INFO
#   tools         : Edit/Write/NotebookEdit DISABLED (checker = no mutation)
#                   Agent DISABLED (no subagents: delegation escapes brief + Stop hook)
#   verdict file  : $VERDICT_FILE   <- $ORCH/logs writable (carveout + --add-dir)
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

# Worktree (idempotent): the checker inspects the PR branch. Reuse if present;
# else base it on the remote PR branch (it must exist — the PR is open).
if [ ! -d "$WORKTREE" ]; then
  if git -C "$WORKING_CLONE" show-ref -q --verify "refs/remotes/origin/$BRANCH"; then
    git -C "$WORKING_CLONE" worktree add "$WORKTREE" -B "$BRANCH" "origin/$BRANCH"
  else
    echo "remote branch origin/$BRANCH missing — cannot check PR #$PR" >&2; exit 1
  fi
fi

# Data bootstrap: identical to the worker's (bootstrap_worktree_data, dispatch-common.sh)
# so the checker's worktree gets the SAME links the worker had — critical because the
# checker re-runs pipeline stages that read raw/+derived/ and write output/. Previously
# the checker only ever created a single `data/raw -> raw_resolved` symlink and never ran
# a repo's own setup-symlinks.sh, so for a multi-tree repo (california-pesticides) it
# pointed data/raw at the whole data dir and left derived/ absent (issue #25).
bootstrap_worktree_data "$WORKTREE" "$RAW_RESOLVED" "$WORKING_CLONE" "$DROPBOX_PROJ" "$REPO_SLUG" "$CRITICAL_PATHS" "$DERIVED_RESOLVED"

# Belt-and-suspenders mutation baseline: capture the worktree's tracked-file state
# before the checker runs; we re-check after, so an accidental write surfaces here
# even if the in-session check missed it. (The brief also has the checker self-report.)
MUTATION_BASELINE="$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)"

# Ledger: checker entries use a `check pr#N` prefix so they DON'T match the worker
# concurrency-count regex (`^- #<digits> |`) — checkers don't consume worker slots.
write_ledger() {  # $1 = pid, $2 = status
  printf -- '- check pr#%s | %s | %s | %s | pid %s | dispatched %s | status %s\n' \
    "$PR" "$REPO" "$BRANCH" "$LOG" "$1" "$(date -u +%FT%TZ)" "$2" >> "$LEDGER"
}

# report_mutation (compares against MUTATION_BASELINE) lives in dispatch-common.sh so
# the detached new-session body can call it too; here we pass the baseline explicitly.

# Clear the canonical verdict path for this new generation (issue #49). On a RE-dispatch
# the previous round's verdict is still sitting there, and watch-dispatch.sh read it as
# this dispatch's — so the new checker was reported terminal within seconds off a stale
# verdict, and a checker that crashed before its first write was reported as a clean pass
# instead of surfacing the crash. (Issue #66 hardened the READER too: `item_state` now
# requires the verdict's mtime to be at/after this dispatch's own ledger timestamp. This
# rotation still matters — it is what keeps a fresh checker's crash visible — but the two
# are independent, so neither leans on the other.) Rotated to one
# `.prev.json` slot rather than `rm`'d: a re-dispatch already overwrites in place today, so
# moving keeps one MORE local generation (the one that matters when a fresh checker dies
# before writing) at no risk of unbounded growth — the PR comment is the durable full copy.
# Deliberately AFTER the --dry-run exit above: a plan-only run must mutate nothing.
# See rotate_verdict_file in dispatch-common.sh for the full rationale.
rotate_verdict_file "$VERDICT_FILE"

echo "Dispatching checker for $REPO PR #$PR (closes #$ISSUE) → $WORKTREE (log: $LOG)"
if [ "$FG" = 1 ]; then
  write_ledger "-" "dispatched"
  # `|| true`: claude exits NONZERO on an interrupted run (budget cap / rate limit /
  # error). Under `set -e` that would abort before report_mutation + finalize_dispatch,
  # losing both the no-mutation proof and the interruption record.
  ( cd "$WORKTREE" && "${CMD[@]}" ) 2>&1 | tee "$LOG" || true
  report_mutation "$WORKTREE" "$MUTATION_BASELINE"
  finalize_dispatch "$LOG" "$LEDGER" "-" "$WORKTREE" "checker"
else
  # Detached + ISOLATED: own session (see run_in_new_session) so the dispatching
  # session's teardown can't reap it. Inside the session: run claude, then
  # report_mutation (no-mutation proof) + finalize_dispatch, all appended to the log.
  run_in_new_session "$LOG" "$LEDGER" "$WORKTREE" "checker" "$MUTATION_BASELINE" -- "${CMD[@]}" &
  CHECKER_PID=$!
  disown 2>/dev/null || true
  write_ledger "$CHECKER_PID" "dispatched"
  echo "  pid $CHECKER_PID  (detached, own session; mutation + completion checks in the log)"
  # `@<pid>` is the dispatch identity watch-dispatch.sh resolves the ledger line by, so a
  # watch armed in this same turn can never report the previous round's verdict or status
  # as this checker's (issue #66 — the verdict-file rotation above narrows that window,
  # this closes it). Printed ready to copy.
  echo "  watch: dr watch-dispatch ${REPO_SLUG}#pr${PR}@${CHECKER_PID}"
fi
