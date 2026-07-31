#!/usr/bin/env bash
# launch-orchestrator.sh — boot an interactive orchestrator session with the
# board digest pre-loaded.
#
# Triggered by hand. It sets ORCHESTRATOR=1 (which activates the env-gated
# SessionStart hook) and injects that hook via --settings, so the session boots
# already holding the board digest — zero tool calls. Human-gated: the session
# proposes dispatches and runs launch-worker.sh / launch-checker.sh only on your
# explicit confirmation (shared posture in briefs/orchestrator-interactive-brief.md,
# also used by the /orchestrate slash command). The autonomous scheduled brain is
# a separate brief (briefs/orchestrator-brief.md), driven by orchestrator-cycle.sh.
#
# The hook is passed only to THIS session via --settings; nothing is written to
# a shared settings file, so ordinary interactive sessions stay untouched.
#
# Usage:
#   ./launch-orchestrator.sh [--dry-run] [extra claude args...]
#   DONE_DAYS=14 ./launch-orchestrator.sh        # widen the Done window
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ORCH/host/hooks/session-start-digest.sh"
BRIEF_FILE="$ORCH/briefs/orchestrator-interactive-brief.md"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && { DRY_RUN=1; shift; }

[ -x "$HOOK" ] || { echo "launch-orchestrator: hook not executable: $HOOK" >&2; exit 1; }
[ -f "$BRIEF_FILE" ] || { echo "launch-orchestrator: brief not found: $BRIEF_FILE" >&2; exit 1; }

# --- register the env-gated digest hook for this session only ------------------
SETTINGS_JSON="$(HOOK="$HOOK" python3 - <<'PY'
import json, os
print(json.dumps({"hooks": {"SessionStart": [
    {"hooks": [{"type": "command", "command": os.environ["HOOK"]}]}
]}}))
PY
)"

# --- orchestrator role brief (shared, human-gated; reports vs. decides) --------
# The interactive role text lives in ONE place — briefs/orchestrator-interactive-brief.md,
# shared verbatim with the /orchestrate slash command (no second copy). It's
# token-free; we append this checkout's absolute path so the launchers referenced
# in the brief resolve regardless of the session's working directory. We lead with
# the `dr` shorthand (matching the now-`dr`-leading brief) but keep the absolute
# $ORCH/bin paths as the guaranteed fallback — `dr` needs ~/.local/bin on PATH,
# the absolute paths always resolve.
BRIEF="$(cat "$BRIEF_FILE")
Your derailleur checkout is at: $ORCH
Dispatch with dr launch-worker and dr launch-checker (both work from any
directory when ~/.local/bin is on PATH); the absolute paths
$ORCH/bin/launch-worker.sh and $ORCH/bin/launch-checker.sh are the
equivalent fallback and always work regardless of PATH."

if [ "$DRY_RUN" = "1" ]; then
  echo "=== board digest (preview) ============================================"
  ORCHESTRATOR=1 "$HOOK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
  echo
  echo "=== would launch ====================================================="
  echo "ORCHESTRATOR=1 claude --settings <digest-hook> --append-system-prompt <brief> $*"
  exit 0
fi

# Tool scope: this launcher sets NO --allowedTools, so the session inherits the
# full interactive toolset — which already includes `Monitor`, the harness tool
# the brief's post-dispatch watch uses (issue #26). Nothing to widen here: unlike
# the /orchestrate slash command (whose allow-list must name `Monitor` explicitly,
# and now does), a launcher-booted session is human-present and deliberately left
# unrestricted, so DON'T add an allow-list here — that would NARROW the scope and
# break the operator's ability to read/inspect during a session. The autonomous
# cycle stays untouched (separate brief + one-shot `claude -p`, which exits before
# Monitor events could arrive).
#
# Subagents (`Agent`) are likewise NOT denied here, and that is deliberate (issue #45).
# The three UNATTENDED dispatches — launch-worker.sh, launch-checker.sh, and the headless
# cycle in orchestrator-cycle.sh — all pass `--disallowedTools … Agent`, because a
# delegated subagent escapes the brief, the Stop-hook exit contract, and the session's
# budget with nobody watching. This session is human-present: the operator sees every
# delegation, can interrupt it, and owns the spend, so the reasons don't apply. Denying
# Agent here would only narrow what the operator can do interactively. DON'T add it.
ORCHESTRATOR=1 exec claude \
  --settings "$SETTINGS_JSON" \
  --append-system-prompt "$BRIEF" \
  "$@"
