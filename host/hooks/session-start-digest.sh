#!/usr/bin/env bash
# session-start-digest.sh — SessionStart hook, ENV-GATED on ORCHESTRATOR=1.
#
# Inert in normal interactive sessions (exits 0, no output) so it never fires
# unless an orchestrator boot set ORCHESTRATOR=1. When active, it runs
# board-digest.sh and injects the result as `additionalContext`, so the
# orchestrator session boots pre-loaded with board state at zero tool calls.
#
# Wired in via --settings by launch-orchestrator.sh (not registered in any
# shared settings file, to keep interactive sessions untouched).
set -euo pipefail

[ "${ORCHESTRATOR:-}" = "1" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST_SH="$HERE/../../board-digest.sh"

if digest="$("$DIGEST_SH" 2>&1)"; then
  :
else
  digest="board-digest.sh failed:
$digest"
fi

DIGEST="$digest" python3 <<'PY'
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ["DIGEST"],
    }
}))
PY
