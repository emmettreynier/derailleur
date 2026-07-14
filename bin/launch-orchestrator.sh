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
# in the brief resolve regardless of the session's working directory.
BRIEF="$(cat "$BRIEF_FILE")
Your derailleur checkout is at: $ORCH
Dispatch with the absolute paths $ORCH/bin/launch-worker.sh and
$ORCH/bin/launch-checker.sh (both work from any directory)."

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
