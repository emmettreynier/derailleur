#!/usr/bin/env bash
# install.sh — orchestrator HOST bootstrap (one-time per machine).
#
# Reproduces the machine-local bits the orchestrator needs, from the repo —
# never from memory. Idempotent: re-running changes nothing.
#
# What it does, and (deliberately) what it does NOT:
#   - checks the host deps the loop assumes (gh, jq, claude, python3, git);
#   - makes the in-repo host hooks + launcher scripts executable;
#   - renders the one opt-in ~/.claude/ file: the /orchestrate slash command
#     (see the carve-out note below);
#   - points you at the two follow-on, opt-in steps it does NOT run for you:
#       * the scheduled launcher  -> ./schedule.sh install   (registers the
#         launchd timer + pmset wakes; needs sudo, so it's separate on purpose)
#       * per-project onboarding  -> ./new-project.sh <owner/repo>
#
# The orchestrator's host hooks (host/hooks/raw-data-guard.py, worker-stop-guard.sh,
# session-start-digest.sh) are wired into each dispatch BY IN-REPO PATH — the
# launchers pass them via --settings / hook flags (see launch-worker.sh,
# launch-checker.sh, launch-orchestrator.sh). They are NOT registered in a shared
# ~/.claude/settings.json, by design, so interactive sessions stay untouched.
#
# The SINGLE, narrow carve-out to "writes nothing to ~/.claude/": the /orchestrate
# slash command, rendered to ~/.claude/commands/orchestrate.md. It is inert until
# the operator types /orchestrate — no SessionStart/hook registration, so it
# changes no default session behavior anywhere. Rendered here (not shipped) so
# this checkout's absolute path is baked in; the write is explicit and logged.
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
# CLT (pulled in by Homebrew); gh/jq/claude/tmux are explicit installs. tmux backs
# bin/tmux-run.sh (a worker's detached long-running jobs — see briefs/worker-brief.md).
missing=0
for dep in gh jq claude python3 git tmux; do
  if command -v "$dep" >/dev/null 2>&1; then
    note "✓ $dep  ($(command -v "$dep"))"
  else
    warn "missing dep: $dep"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || die "install missing deps and re-run (gh, jq, git, tmux via Homebrew; claude via npm), then 'gh auth login'."

# gh must be authenticated or every dispatch fails at the first API call.
if gh auth status >/dev/null 2>&1; then
  note "✓ gh authenticated"
else
  warn "gh is not authenticated — run 'gh auth login' before dispatching."
fi

# --- executability of in-repo host pieces ------------------------------------
# Git preserves the +x bit, so on a fresh clone these are already executable;
# we re-assert it so a hand-edited or odd-umask checkout still works. Idempotent.
# NB: dispatch-common.sh and config-common.sh are SOURCED (libs), not executed —
# leave them non-exec so install.sh doesn't churn a mode bit into a perpetual dirty diff.
chmod_ok() { [ -f "$1" ] && chmod +x "$1"; }
for f in \
  "$ORCH"/host/hooks/raw-data-guard.py \
  "$ORCH"/host/hooks/worker-stop-guard.sh \
  "$ORCH"/host/hooks/session-start-digest.sh \
  "$ORCH"/bin/*.sh
do
  case "$f" in */dispatch-common.sh|*/config-common.sh) continue ;; esac
  chmod_ok "$f"
done
note "✓ host hooks + launcher scripts marked executable"

# --- working dirs the loop writes to -----------------------------------------
# logs/ and state/ are gitignored machine-local scratch; create them so the first
# cycle (or schedule.sh) doesn't have to.
mkdir -p "$ORCH/logs" "$ORCH/state"
note "✓ logs/ and state/ present"

# --- per-operator identity config (gitignored; scaffold from the tracked example) --
# The scripts source orchestrator.conf to learn who this instance runs as. Scaffold
# it from the example on first install; never clobber an existing one.
if [ -f "$ORCH/orchestrator.conf" ]; then
  note "✓ orchestrator.conf present"
else
  cp "$ORCH/orchestrator.conf.example" "$ORCH/orchestrator.conf"
  warn "scaffolded orchestrator.conf from the example — EDIT it with your identity"
  warn "  (OPERATOR_NAME / GITHUB_HANDLE / PR_OWNER / LAUNCHD_LABEL / BOARD_PROJECT) before dispatching."
fi

# --- opt-in /orchestrate slash command (the one ~/.claude/ carve-out) ---------
# Render templates/orchestrate.command.md -> ~/.claude/commands/orchestrate.md with
# this checkout's absolute path baked into {{DERAILLEUR_ROOT}}. Idempotent: rewrites
# only when the rendered content differs, so a re-run is a no-op. Inert until typed;
# no hooks registered, so ordinary interactive sessions elsewhere are untouched.
CMD_TEMPLATE="$ORCH/templates/orchestrate.command.md"
CMD_DEST="$HOME/.claude/commands/orchestrate.md"
cmd_in_repo=""
if [ -f "$CMD_TEMPLATE" ]; then
  mkdir -p "$(dirname "$CMD_DEST")"
  # The rendered command bakes in THIS checkout's absolute path — a machine-local
  # artifact that must never be committed. But ~/.claude/commands is not always a
  # plain directory: a machine bootstrap may symlink it into a versioned dotfiles
  # repo, in which case writing here silently drops a machine-specific file into a
  # shared git tree (it then gets committed and breaks every other machine). Resolve
  # the target through symlinks (pwd -P is load-bearing — the symlink is what hides
  # the repo from a naive check) and warn loudly if it lands inside a work tree.
  real_dest="$(cd "$(dirname "$CMD_DEST")" && pwd -P)"
  if git -C "$real_dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cmd_in_repo="$(git -C "$real_dest" rev-parse --show-toplevel 2>/dev/null || echo "$real_dest")"
    warn "render target resolves inside a git repo: $cmd_in_repo"
    warn "  orchestrate.md is machine-specific (it bakes in $ORCH) and must NOT be committed."
    warn "  gitignore it there, or point ~/.claude/commands at an unversioned directory."
  fi
  # Substitute the placeholder and drop the leading source-only HTML comment so
  # the YAML frontmatter is the first line of the rendered command.
  rendered="$(ORCH="$ORCH" CMD_TEMPLATE="$CMD_TEMPLATE" python3 - <<'PY'
import os
src = open(os.environ["CMD_TEMPLATE"]).read()
src = src[src.find("---"):]                      # frontmatter onward (drop the comment)
print(src.replace("{{DERAILLEUR_ROOT}}", os.environ["ORCH"]), end="")
PY
)"
  if [ -f "$CMD_DEST" ] && [ "$(cat "$CMD_DEST")" = "$rendered" ]; then
    note "✓ ~/.claude/commands/orchestrate.md up to date (no change)"
  else
    printf '%s\n' "$rendered" > "$CMD_DEST"
    note "✓ rendered ~/.claude/commands/orchestrate.md  (DERAILLEUR_ROOT=$ORCH)"
  fi
else
  warn "template missing: $CMD_TEMPLATE — skipped /orchestrate command render"
fi

# --- CLI dispatcher on PATH (derailleur / dr) --------------------------------
# Symlink the extensionless bin/derailleur dispatcher onto the user's PATH so any
# command runs from anywhere as `derailleur <cmd>` / `dr <cmd>` instead of
# ./bin/<cmd>.sh. The dispatcher walks the symlink back to THIS checkout (it bakes
# in no path), so moving the repo just needs a re-run of install.sh — the symlink
# is stale until then (same caveat as /orchestrate above). Idempotent: we refresh
# the symlink each run and never clobber a non-symlink of the same name.
CLI_SRC="$ORCH/bin/derailleur"
CLI_BIN_DIR="$HOME/.local/bin"
if [ -f "$CLI_SRC" ]; then
  chmod +x "$CLI_SRC"
  mkdir -p "$CLI_BIN_DIR"
  linked=0
  for name in derailleur dr; do
    dest="$CLI_BIN_DIR/$name"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      warn "not overwriting $dest — a non-symlink file already exists there (remove it and re-run to link '$name')."
      continue
    fi
    ln -sf "$CLI_SRC" "$dest"
    linked=$((linked + 1))
  done
  [ "$linked" -gt 0 ] && note "✓ linked derailleur + dr into $CLI_BIN_DIR"
  case ":$PATH:" in
    *":$CLI_BIN_DIR:"*) note "✓ $CLI_BIN_DIR is on your PATH" ;;
    *)
      warn "$CLI_BIN_DIR is not on your PATH — add this line to ~/.zshrc, then restart your shell:"
      warn '    export PATH="$HOME/.local/bin:$PATH"'
      ;;
  esac
else
  warn "dispatcher missing: $CLI_SRC — skipped derailleur/dr link"
fi

# --- next steps (opt-in; this script does not run them) -----------------------
cat <<EOF

orchestrator host bootstrap complete.

Next, as needed:
  1. Onboard a project:        dr new-project <owner/repo>
  2. Install the night timer:  dr schedule install   (ships PLAN-ONLY)
                               then dr schedule live  when ready to spend
  3. Sanity check:             dr board-digest   (reads the board)

See README.md for the full host + per-project checklists.
EOF

if [ -n "$cmd_in_repo" ]; then
  warn ""
  warn "NOTE: ~/.claude/commands/orchestrate.md was written into a git repo ($cmd_in_repo)."
  warn "      It is machine-specific — gitignore it there or repoint ~/.claude/commands"
  warn "      before it gets committed. See README → install."
fi
