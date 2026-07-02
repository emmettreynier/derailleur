#!/usr/bin/env bash
# install.sh — orchestrator HOST bootstrap (one-time per machine).
#
# Reproduces the machine-local bits the orchestrator needs, from the repo —
# never from memory. Idempotent: re-running changes nothing.
#
# What it does, and (deliberately) what it does NOT:
#   - checks the host deps the loop assumes (gh, jq, claude, python3, git);
#   - makes the in-repo host hooks + launcher scripts executable;
#   - points you at the two follow-on, opt-in steps it does NOT run for you:
#       * the scheduled launcher  -> ./schedule.sh install   (registers the
#         launchd timer + pmset wakes; needs sudo, so it's separate on purpose)
#       * per-project onboarding  -> ./new-project.sh <owner/repo>
#
# It intentionally does NOT symlink anything into ~/.claude/. The orchestrator's
# host hooks (host/hooks/raw-data-guard.py, worker-stop-guard.sh,
# session-start-digest.sh) are wired into each dispatch BY IN-REPO PATH — the
# launchers pass them via --settings / hook flags (see launch-worker.sh,
# launch-checker.sh, launch-orchestrator.sh). They are NOT registered in a shared
# ~/.claude/settings.json, by design, so interactive sessions stay untouched.
# Your personal ~/.claude config (CLAUDE.md, settings.json, hooks/, skills/) is a
# separate concern, owned by your machine bootstrap (e.g. project-management-v2's
# bootstrap/install.sh), which symlinks it canonical-in-repo -> ~/.claude.
#
# Usage: ./install.sh
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root

note() { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- deps ---------------------------------------------------------------------
# Hard deps: the loop cannot run without these. python3 + git ship with the Xcode
# CLT (pulled in by Homebrew); gh/jq/claude are explicit installs.
missing=0
for dep in gh jq claude python3 git; do
  if command -v "$dep" >/dev/null 2>&1; then
    note "✓ $dep  ($(command -v "$dep"))"
  else
    warn "missing dep: $dep"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || die "install missing deps and re-run (gh, jq, git via Homebrew; claude via npm), then 'gh auth login'."

# gh must be authenticated or every dispatch fails at the first API call.
if gh auth status >/dev/null 2>&1; then
  note "✓ gh authenticated"
else
  warn "gh is not authenticated — run 'gh auth login' before dispatching."
fi

# --- executability of in-repo host pieces ------------------------------------
# Git preserves the +x bit, so on a fresh clone these are already executable;
# we re-assert it so a hand-edited or odd-umask checkout still works. Idempotent.
# NB: dispatch-common.sh is SOURCED (a lib), not executed — leave it non-exec so
# install.sh doesn't churn its mode bit into a perpetual dirty diff.
chmod_ok() { [ -f "$1" ] && chmod +x "$1"; }
for f in \
  "$ORCH"/host/hooks/raw-data-guard.py \
  "$ORCH"/host/hooks/worker-stop-guard.sh \
  "$ORCH"/host/hooks/session-start-digest.sh \
  "$ORCH"/bin/*.sh
do
  case "$f" in */dispatch-common.sh) continue ;; esac
  chmod_ok "$f"
done
note "✓ host hooks + launcher scripts marked executable"

# --- working dirs the loop writes to -----------------------------------------
# logs/ and state/ are gitignored machine-local scratch; create them so the first
# cycle (or schedule.sh) doesn't have to.
mkdir -p "$ORCH/logs" "$ORCH/state"
note "✓ logs/ and state/ present"

# --- next steps (opt-in; this script does not run them) -----------------------
cat <<EOF

orchestrator host bootstrap complete.

Next, as needed:
  1. Onboard a project:        ./bin/new-project.sh <owner/repo>
  2. Install the night timer:  ./bin/schedule.sh install   (ships PLAN-ONLY)
                               then ./bin/schedule.sh live  when ready to spend
  3. Sanity check:             ./bin/board-digest.sh   (reads the board)

See README.md for the full host + per-project checklists.
EOF
