#!/usr/bin/env bash
# orchestrator-cycle.sh — one orchestration pass (the Phase 4 dispatch brain).
#
# Order of a cycle:
#   1. prune the ledger (drop completed/dead workers + checkers) and reclaim disk
#      by removing worktrees whose branch is merged/closed (work captured on GitHub)
#   2. dispatch CHECKERS on ready PRs (deterministic — a ready PR IS the request
#      to be checked; no model judgment needed)
#   3. if under the worker concurrency cap, boot a headless orchestrator that reads
#      the injected board digest, applies the intake gate, and dispatches up to the
#      remaining slots via launch-worker.sh
# This is what a launchd schedule (or you, by hand) calls to make the loop run.
#
# Usage: orchestrator-cycle.sh [--dry-run]
#   --dry-run  PLAN only: checkers/workers are launched with --dry-run (spend/mutate
#              nothing) and the orchestrator must not touch labels — for validating
#              judgment before letting it dispatch for real.
#
# Env:
#   CAP             worker concurrency cap — max workers in flight at once (default 2)
#   BUDGET          orchestrator session budget in USD (default 2.00)
#   MODEL           orchestrator session model (default sonnet — it reads the digest
#                   and routes; pinning it keeps the cycle off whatever expensive
#                   default an interactive session happens to be set to)
#   WORKER_BUDGET   per-worker session budget in USD (default 10.00)
#   CHECKER_BUDGET  per-checker session budget in USD (default 3.00)
#   CHECKER_LIMIT   max checker rounds per PR before escalating to the operator (default 4)
#   WORKER_LIMIT    max consecutive interrupted worker attempts on one issue before
#                   escalating to the operator instead of retrying again (default 4)
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ORCH/bin/config-common.sh"   # OPERATOR_NAME, GITHUB_HANDLE (escalation @-mention)
CAP="${CAP:-2}"
BUDGET="${BUDGET:-2.00}"
MODEL="${MODEL:-sonnet}"
WORKER_BUDGET="${WORKER_BUDGET:-10.00}"
CHECKER_BUDGET="${CHECKER_BUDGET:-3.00}"
CHECKER_LIMIT="${CHECKER_LIMIT:-4}"
WORKER_LIMIT="${WORKER_LIMIT:-4}"
BRIEF_FILE="$ORCH/briefs/orchestrator-brief.md"
LEDGER="$ORCH/ledger.md"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Plan-only is a MECHANICAL gate, not just advice to the planning model. Without
# this, a --dry-run cycle only *told* the headless orchestrator (booted below with
# bypassPermissions) to pass --dry-run to launch-worker.sh — nothing stopped it from
# omitting the flag and dispatching a real, spending worker, which is exactly what
# happened in issue #18. Exporting ORCH_PLAN_ONLY=1 makes every dispatch launcher
# (launch-worker.sh / launch-checker.sh) force --dry-run by construction, so a
# plan-only cycle *cannot* spend regardless of what the model does. The var is
# inherited by the launcher subprocesses the model runs via its Bash tool (same
# env-inheritance the ORCHESTRATOR=1 SessionStart gate relies on), and is unset in
# any direct/interactive dispatch, so it only ever tightens the autonomous cycle.
[ "$DRY" = 1 ] && export ORCH_PLAN_ONLY=1

command -v claude >/dev/null || { echo "orchestrator-cycle: claude not found" >&2; exit 1; }
[ -f "$BRIEF_FILE" ] || { echo "orchestrator brief missing: $BRIEF_FILE" >&2; exit 1; }

# Render a brief .md file into a system-prompt string (strip header comment, fill {{TOKEN}}).
render_brief() {
  python3 - "$1" <<'PY'
import os, re, sys
text = re.sub(r'^<!--.*?-->\n', '', open(sys.argv[1]).read(), count=1, flags=re.S)
print(re.sub(r'{{(\w+)}}',
             lambda m: os.environ.get('BRIEF_' + m.group(1), m.group(0)),
             text), end='')
PY
}

# read a scalar field from a manifest
yml() { sed -nE "s/^$2:[[:space:]]*(.+)/\1/p" "$1" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }

# 1. Prune stale entries so the live count is accurate -------------------------
WORKER_LIMIT="$WORKER_LIMIT" "$ORCH/bin/ledger-prune.sh" || true

# 1b. Reclaim disk: remove worktrees whose work is merged/closed and already
# captured on GitHub (a spent derivative). Conservative — never touches a live
# in-flight worktree or any local-only (uncommitted/unpushed) state. Honors
# --dry-run so a planning pass reports removals without touching the filesystem.
if [ "$DRY" = 1 ]; then
  "$ORCH/bin/worktree-prune.sh" --auto --dry-run || true
else
  "$ORCH/bin/worktree-prune.sh" --auto || true
fi

# 2. Onboarded repos — only these are in the loop (they have a manifest) --------
# A non-empty state/scheduled-repos allow-list (read via the shared scheduled_repos
# helper in config-common.sh) further restricts AUTONOMOUS dispatch to the listed
# slugs; absent/empty ⇒ all onboarded repos (today's behavior). Applied at BOTH the
# SLUGS computation (worker brief) below and the checker loop (section 3) so the gate
# covers every autonomous pass — whether fired by run-cycle.sh (cron) or run by hand.
# Manual launch-*.sh and interactive /orchestrate are unaffected (they never read it).
ALLOW="$(scheduled_repos)"   # newline-separated; empty ⇒ no allow-list in effect

# is_scheduled <slug> — true when the allow-list is empty (all onboarded live) or the
# slug is listed. A predicate: its exit status is the answer, so callers must use it in
# a conditional (`if is_scheduled …`). Branches on ALLOW emptiness to avoid the bash 3.2
# empty-array trap (CLAUDE.md); never expands ALLOW into an array.
is_scheduled() {
  [ -z "$ALLOW" ] && return 0
  grep -qxF "$1" <<<"$ALLOW"
}

if [ -n "$ALLOW" ]; then
  echo "— allow-list active (state/scheduled-repos): autonomous dispatch restricted to: $(echo "$ALLOW" | paste -sd' ' -)"
  # A listed slug with no manifest can never dispatch — warn (never silently drop).
  while IFS= read -r _s; do
    [ -n "$_s" ] || continue
    [ -f "$ORCH/projects/$_s.yml" ] \
      || echo "  ⚠ scheduled-repos: '$_s' is not onboarded (no projects/$_s.yml) — ignored"
  done <<< "$ALLOW"
fi

# Onboarded slugs (manifest present), then keep only those the allow-list permits.
ONBOARDED=$(ls "$ORCH/projects/"*.yml 2>/dev/null | xargs -n1 basename 2>/dev/null \
              | sed 's/\.yml$//' || true)
SLUGS=""
for _s in $ONBOARDED; do
  is_scheduled "$_s" || continue
  SLUGS="${SLUGS:+$SLUGS,}$_s"
done
if [ -z "$SLUGS" ]; then
  if [ -z "$ONBOARDED" ]; then
    echo "no onboarded projects (projects/*.yml) — nothing to do."
  else
    echo "allow-list (state/scheduled-repos) excludes every onboarded repo — nothing to dispatch."
  fi
  exit 0
fi

# 3. Dispatch checkers on ready, not-yet-approved PRs --------------------------
# Deterministic: a PR marked ready (un-drafted) IS the "check me" signal — no LLM
# judgment needed. Skip PRs already approved (the operator's merge gate), escalated
# (needs-input — their court), or with a checker already in flight (the ledger).
echo "— checker pass —"
for f in "$ORCH"/projects/*.yml; do
  [ -f "$f" ] || continue
  slug="$(basename "$f" .yml)"
  # Same allow-list gate as the worker pass: skip checkers for repos the allow-list
  # excludes (autonomous scope only — manual launch-checker.sh still works on them).
  if ! is_scheduled "$slug"; then
    echo "  $slug — excluded by allow-list (state/scheduled-repos), skip"; continue
  fi
  repo="$(yml "$f" repo)"
  [ -n "$repo" ] || continue
  # ready, not-approved PRs that close an issue -> emit "<pr> <issue>" pairs.
  PRS="$(gh pr list -R "$repo" --state open \
           --json number,isDraft,reviewDecision,closingIssuesReferences 2>/dev/null \
         | python3 -c '
import sys, json
for pr in json.load(sys.stdin):
    if pr.get("isDraft"): continue
    if pr.get("reviewDecision") == "APPROVED": continue          # human-approved -> operator
    refs = pr.get("closingIssuesReferences") or []
    if not refs: continue                                        # no acceptance criteria
    print(pr["number"], refs[0]["number"])
' 2>/dev/null || true)"
  while read -r pr issue; do
    [ -n "$pr" ] || continue
    if grep -q "check pr#$pr |" "$LEDGER" 2>/dev/null; then
      echo "  $slug PR #$pr — checker already in flight, skip"; continue
    fi
    # Routing labels live on the issue: skip a PR already passed, escalated, or
    # handed back to the worker (resume) — none of those are the checker's court.
    ILABS="$(gh issue view "$issue" -R "$repo" --json labels -q '.labels[].name' 2>/dev/null || true)"
    if grep -qxE 'checked-pass|needs-input|resume' <<<"$ILABS"; then
      echo "  $slug PR #$pr — issue #$issue is passed/escalated/handed-back, skip"; continue
    fi
    # Backstop against a worker<->checker ping-pong: if this PR has been through
    # CHECKER_LIMIT rounds *in the current review generation* without converging,
    # stop checking and escalate to the operator (the holdout is almost certainly a
    # research call a worker can't settle). Rounds are counted PER GENERATION, not
    # over the PR's lifetime: a pass / pass_with_findings / blocked verdict hands the
    # ball to the operator and ends a generation; changes_requested / fail keeps it
    # worker-side. So we count only the verdict comments AFTER the most recent
    # to-operator verdict — once the operator has reviewed and bounced, the next check is
    # round 1 again, not round N. (Verdict comments are led by "**Checker verdict:".)
    NROUNDS="$(gh pr view "$pr" -R "$repo" --json comments 2>/dev/null \
      | python3 -c '
import sys, json, re
try:
    comments = json.load(sys.stdin).get("comments", [])
except Exception:
    print(0); sys.exit()
verdicts = [c["body"] for c in comments if c["body"].startswith("**Checker verdict")]
to_operator = {"pass", "pass_with_findings", "blocked"}   # verdicts that end a generation
last_handoff = -1
for i, b in enumerate(verdicts):
    m = re.match(r"\*\*Checker verdict:\s*`?\s*([a-z_]+)", b, re.I)
    if (m.group(1).lower() if m else "") in to_operator:
        last_handoff = i
print(len(verdicts) - (last_handoff + 1))
' 2>/dev/null || echo 0)"
    if [ "${NROUNDS:-0}" -ge "$CHECKER_LIMIT" ]; then
      echo "  $slug PR #$pr — $NROUNDS checker rounds (limit $CHECKER_LIMIT); escalating to $OPERATOR_NAME"
      if [ "$DRY" = 0 ]; then
        gh issue edit "$issue" -R "$repo" --add-label needs-input 2>/dev/null || true
        gh pr comment "$pr" -R "$repo" --body "🔁 Checker limit reached: $NROUNDS checker rounds without a clean pass. Escalating to @$GITHUB_HANDLE — the unresolved finding is likely a research-judgment call a worker can't settle. Labeled needs-input."
      fi
      continue
    fi
    if [ "$DRY" = 1 ]; then
      echo "  would check: $slug PR #$pr (closes #$issue)"
      "$ORCH/bin/launch-checker.sh" "$slug" "$pr" --budget "$CHECKER_BUDGET" --dry-run >/dev/null && echo "    (dry-run command assembled OK)"
    else
      "$ORCH/bin/launch-checker.sh" "$slug" "$pr" --budget "$CHECKER_BUDGET"
    fi
  done <<< "$PRS"
done

# 4. Count live workers; skip worker dispatch if at capacity -------------------
# Only worker lines (`- #<digits> |`) count toward the cap; checker lines
# (`- check pr#N |`) deliberately don't match this regex.
LIVE=$(grep -cE '^- #[0-9]+[[:space:]]*\|' "$LEDGER" 2>/dev/null || true)
LIVE=${LIVE:-0}
SLOTS=$(( CAP - LIVE ))
echo "— worker pass — live=$LIVE cap=$CAP slots=$SLOTS dry_run=$DRY"
if [ "$SLOTS" -le 0 ]; then
  echo "at worker capacity — no worker dispatch this cycle."
  exit 0
fi

# 5. Compose the worker-dispatch brief + invocation ---------------------------
HOOK="$ORCH/host/hooks/session-start-digest.sh"
SETTINGS_JSON="$(HOOK="$HOOK" python3 -c 'import json,os; print(json.dumps({"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":os.environ["HOOK"]}]}]}}))')"
DISPATCH="$ORCH/bin/launch-worker.sh"

if [ "$DRY" = 1 ]; then
  DISPATCH_LINE="$DISPATCH <repo-slug> <issue#> --budget $WORKER_BUDGET --dry-run"
  MUTATE_RULE="DRY RUN — change nothing on GitHub. Do NOT run \`gh issue edit\` or add
labels; instead, for each candidate, PRINT your decision (dispatch / bounce to
needs-definition / skip) and the exact command you would run. You may run
\`launch-worker.sh ... --dry-run\` (it spends and mutates nothing) to show the
fully-assembled dispatch, and read-only \`gh issue view\`."
else
  DISPATCH_LINE="$DISPATCH <repo-slug> <issue#> --budget $WORKER_BUDGET"
  MUTATE_RULE="For an under-specified issue, label it and move on:
\`gh issue edit <issue#> -R <owner/repo> --add-label needs-definition\`."
fi

BRIEF="$(BRIEF_SLOTS="$SLOTS" BRIEF_SLUGS="$SLUGS" \
         BRIEF_DISPATCH_LINE="$DISPATCH_LINE" BRIEF_MUTATE_RULE="$MUTATE_RULE" \
         BRIEF_OPERATOR_NAME="$OPERATOR_NAME" \
         render_brief "$BRIEF_FILE")"

TASK="Run one orchestration cycle. From the injected board digest, dispatch up to $SLOTS worker(s) on well-specified, onboarded issues and handle under-specified ones per your brief. Follow the brief exactly."

# 6. Boot the headless orchestrator (board-only: no Edit/Write; budget-capped) -
echo "Booting orchestrator (model $MODEL, budget \$$BUDGET)…"
ORCHESTRATOR=1 claude -p "$TASK" \
  --settings "$SETTINGS_JSON" \
  --append-system-prompt "$BRIEF" \
  --model "$MODEL" \
  --permission-mode bypassPermissions \
  --disallowedTools Edit Write NotebookEdit \
  --max-budget-usd "$BUDGET" \
  --output-format json \
  | python3 -c 'import sys, json
d = json.load(sys.stdin)
print("\n=== orchestrator result ===")
# A killed session (budget cap, rate limit, crash) carries no "result" key — only
# is_error + errors + terminal_reason. Surface that: a bare "(no result)" reads like
# "the orchestrator had nothing to dispatch" when it actually never got to decide.
if d.get("is_error"):
    print("ORCHESTRATOR DID NOT FINISH — " + str(d.get("subtype") or "error")
          + " (terminal_reason: " + str(d.get("terminal_reason") or "unknown") + ")")
    for e in d.get("errors") or ["(no error detail)"]:
        print("  ! " + str(e))
    if d.get("result"):
        print("\npartial result:\n" + str(d["result"]))
    print("\nNothing was dispatched this cycle. If the budget was exhausted, re-run with"
          " a higher BUDGET (e.g. BUDGET=4 dr orchestrator-cycle).")
else:
    print(d.get("result") or "(no result)")
print("\ncost: $" + str(round(d.get("total_cost_usd", 0), 4)))'
