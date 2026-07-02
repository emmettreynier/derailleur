#!/usr/bin/env bash
# launch-orchestrator.sh — boot an interactive orchestrator session with the
# board digest pre-loaded.
#
# Phase 1: triggered by hand. It sets ORCHESTRATOR=1 (which activates the
# env-gated SessionStart hook) and injects that hook via --settings, so the
# session boots already holding the board digest — zero tool calls — and you
# decide what to dispatch, then launch workers by hand with launch-worker.sh.
# Phase 4 will fire this on a schedule and let the model dispatch autonomously.
#
# The hook is passed only to THIS session via --settings; nothing is written to
# a shared settings file, so ordinary interactive sessions stay untouched.
#
# Usage:
#   ./launch-orchestrator.sh [--dry-run] [extra claude args...]
#   DONE_DAYS=14 ./launch-orchestrator.sh        # widen the Done window
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$ORCH/host/hooks/session-start-digest.sh"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && { DRY_RUN=1; shift; }

[ -x "$HOOK" ] || { echo "launch-orchestrator: hook not executable: $HOOK" >&2; exit 1; }

# --- register the env-gated digest hook for this session only ------------------
SETTINGS_JSON="$(HOOK="$HOOK" python3 - <<'PY'
import json, os
print(json.dumps({"hooks": {"SessionStart": [
    {"hooks": [{"type": "command", "command": os.environ["HOOK"]}]}
]}}))
PY
)"

# --- orchestrator role brief (board-only; reports vs. decides) -----------------
read -r -d '' BRIEF <<'BRIEF_EOF' || true
You are the orchestrator for Emmett's research work. A board digest was injected
at session start (additionalContext) — read it first; it is your view of the
FSE Research board, in-flight workers (ledger), needs-input/needs-definition,
resume issues, and ready-for-review PRs.

Your job is to DECIDE what to dispatch — the digest only reports. Rules:
- Dispatch a worker only on a well-specified issue (clear goal + acceptance
  criteria + defined outputs). Each actionable candidate in the digest carries
  its acceptance-criteria checkboxes (or a flag when it has none) — judge
  specification from that. If a candidate is borderline, or you need detail the
  excerpt omits, run `gh issue view <n> -R <repo> --comments` before deciding;
  never dispatch on a guess. If an issue is materially under-specified, do not
  dispatch and do not invent the spec: label it needs-definition and surface it.
- resume issues are the worker's court — dispatch those first.
- Never dispatch anything labeled hold or blocked, or already in-flight (ledger).
- Comment = content, label = signal. Route by labels; never interpret prose into
  action on Emmett's behalf for substantive calls — escalate those to him.
- Phase 1: you propose; Emmett dispatches by hand via launch-worker.sh. Tell him
  exactly which issue(s) you'd dispatch and why, and what needs his input.
BRIEF_EOF

if [ "$DRY_RUN" = "1" ]; then
  echo "=== board digest (preview) ============================================"
  ORCHESTRATOR=1 "$HOOK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
  echo
  echo "=== would launch ====================================================="
  echo "ORCHESTRATOR=1 claude --settings <digest-hook> --append-system-prompt <brief> $*"
  exit 0
fi

ORCHESTRATOR=1 exec claude \
  --settings "$SETTINGS_JSON" \
  --append-system-prompt "$BRIEF" \
  "$@"
