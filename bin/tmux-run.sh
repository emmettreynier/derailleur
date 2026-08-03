#!/usr/bin/env bash
# tmux-run.sh — MECHANICAL detached-run wrapper for a worker's long-running command.
#
# WHY: a worker runs under a budget cap and can be killed mid-run at any moment, which
# would take an inline child process down with it and lose all in-flight compute. The
# fix (convention from #19, now executable here) is to run any long command detached in
# a tmux session whose name is a PURE FUNCTION of the task, so the run survives worker
# death and the NEXT dispatch reattaches instead of restarting from zero. The atomic
# `tmux new-session` doubles as a cross-worker mutex: exactly one worker creates the
# session; a colliding second worker's create fails and this wrapper reports the
# existing one rather than spawning a duplicate.
#
# RESPONSIBILITY LINE — this wrapper is MECHANICAL ONLY. It derives the canonical name
# + durable log path from the project manifest, does the atomic create-or-fail mutex,
# and reports status. It makes NO semantic call: whether outputs are present, whether
# the code is stale, and any `tmux kill-session` teardown are the WORKER's job. No
# project-specific judgment lives in this generic script.
#
# Usage:
#   tmux-run.sh <repo-slug> <issue> -- <cmd...>     # launch (or reattach to) a run
#   tmux-run.sh <repo-slug> <issue> --dry-run       # print what it WOULD do; create nothing
#
#   <repo-slug>  matches projects/<repo-slug>.yml (the launcher's manifest key, e.g.
#                distance-decay-est — NOT owner/repo). The wrapper reads the manifest's
#                `repo:` and `data_root:` itself, so the worker passes only slug/issue/cmd.
#   <cmd...>     everything after `--` is the command to run detached. Each argument is
#                preserved verbatim (shell-quoted); the wrapper appends `2>&1 | tee <log>`.
#   --tail N     on an existing session, show the last N lines of its log (default 20,
#                or $TMUX_RUN_TAIL). The flag wins over the env var.
#
# Canonical name : derail-<owner-repo>-<issue>   (<owner-repo> = manifest `repo:` with /->-)
# Durable log    : <data_root>/logs/derail-<owner-repo>-<issue>.log
#                  (outside the prunable worktree; recomputable from slug+issue).
#
# Status contract — the FIRST stdout line is fixed and parseable:
#   tmux-run: status=created|exists-alive|exists-dead name=<name> log=<path>
# When a session already exists, the last lines of its log follow. Exit 0 = created or
# found; nonzero (with a message) = error (bad args, tmux missing, manifest/data_root
# missing).
set -euo pipefail

# --- locate self as repo root (per CLAUDE.md convention: /.. to the repo root) ---
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "tmux-run: $*" >&2; exit 1; }

TAIL_LINES="${TMUX_RUN_TAIL:-20}"   # log-tail length on an existing session (env/default; --tail overrides)

# --- args ---------------------------------------------------------------------
# Positional slug/issue first (mirrors launch-worker.sh), then optional flags, then
# `-- <cmd...>`. In --dry-run the `--`/command may be omitted (validation convenience).
REPO_SLUG="${1:?usage: tmux-run.sh <repo-slug> <issue> -- <cmd...>  (or --dry-run)}"
ISSUE="${2:?usage: tmux-run.sh <repo-slug> <issue> -- <cmd...>  (or --dry-run)}"
shift 2

DRY=0
HAVE_CMD=0
CMD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --tail)
      [ $# -ge 2 ] || die "--tail needs a number (usage: --tail N)"
      case "$2" in ''|*[!0-9]*) die "--tail needs a non-negative integer, got: $2" ;; esac
      TAIL_LINES="$2"; shift 2 ;;
    --) shift; HAVE_CMD=1; [ $# -gt 0 ] && CMD_ARGS=("$@"); break ;;
    *) die "unexpected arg before '--': $1 (usage: tmux-run.sh <repo-slug> <issue> [--tail N] -- <cmd...>)" ;;
  esac
done

# --- manifest → repo + data_root (reuses launch-worker.sh's readers) -----------
MANIFEST="$ORCH/projects/$REPO_SLUG.yml"
[ -f "$MANIFEST" ] || die "no manifest for '$REPO_SLUG': $MANIFEST"

# Scalar reader: strip trailing '# comment' and surrounding quotes; first match wins.
yml()    { sed -nE "s/^$1:[[:space:]]*(.+)/\1/p" "$MANIFEST" \
             | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
expand() { eval echo "$1"; }   # ~ and $VAR expansion for path fields

REPO="$(yml repo)"
DATA_ROOT="$(expand "$(yml data_root)")"
[ -n "$REPO" ]      || die "manifest $MANIFEST has no 'repo:' field"
[ -n "$DATA_ROOT" ] || die "manifest $MANIFEST has a blank 'data_root:' — set it before dispatching long jobs"

# --- canonical name + durable log path (pure function of the task) -------------
OWNER_REPO="${REPO//\//-}"                 # owner/repo -> owner-repo
NAME="derail-$OWNER_REPO-$ISSUE"
LOGDIR="$DATA_ROOT/logs"
LOG="$LOGDIR/$NAME.log"

# --- dry run: print name/log/would-run command; create NOTHING, spend nothing --
if [ "$DRY" = 1 ]; then
  if [ "${#CMD_ARGS[@]}" -gt 0 ]; then
    cmd_str=""; for a in "${CMD_ARGS[@]}"; do cmd_str="$cmd_str$(printf '%q ' "$a")"; done
    would="tmux new-session -d -s $NAME '${cmd_str}2>&1 | tee $(printf '%q' "$LOG")'"
  else
    would="tmux new-session -d -s $NAME '<cmd> 2>&1 | tee $(printf '%q' "$LOG")'"
  fi
  would="$would \\; set-option -w -t $NAME remain-on-exit on"   # armed in the same invocation
  cat <<INFO
# DRY RUN — tmux-run for $REPO issue #$ISSUE
#   manifest : $MANIFEST
#   session  : $NAME
#   log dir  : $LOGDIR   (would be created with mkdir -p)
#   log      : $LOG
# Would run:
#   $would
INFO
  exit 0
fi

# --- real run: requires tmux + a command ---------------------------------------
command -v tmux >/dev/null 2>&1 || die "tmux not found — install it (see README Requirements)."
[ "$HAVE_CMD" = 1 ]             || die "missing '--': usage: tmux-run.sh <repo-slug> <issue> -- <cmd...>"
[ "${#CMD_ARGS[@]}" -gt 0 ]     || die "no command after '--': usage: tmux-run.sh <repo-slug> <issue> -- <cmd...>"

mkdir -p "$LOGDIR"

# Build the wrapped command string. Each user arg is shell-quoted (%q) so it survives
# tmux's `sh -c` verbatim; we append the tee that mirrors stdout+stderr to the durable
# log (log path quoted too — a Dropbox data_root can contain spaces).
CMD_STR=""; for a in "${CMD_ARGS[@]}"; do CMD_STR="$CMD_STR$(printf '%q ' "$a")"; done
WRAPPED="${CMD_STR}2>&1 | tee $(printf '%q' "$LOG")"

# ATOMIC CREATE IS THE MUTEX. `tmux new-session` succeeds for exactly one worker; a
# colliding create fails on the name. We do NOT probe-then-create (that has a race) and
# we NEVER create a second session under another name — on failure we report the
# existing one. A new-session failure with NO such session is a genuine tmux error.
#
# WHY `remain-on-exit` IS ARMED IN THE SAME tmux INVOCATION AS THE CREATE (issue #54 —
# do NOT re-split this into two calls): the option keeps a finished session lingering as
# a DEAD pane, so a reconciling worker sees 'exists-dead' and can read the log instead of
# the session silently vanishing on completion. tmux runs a command list to completion
# before its event loop reaps the pane's exit, so `\; set-option` here is armed before
# the command can finish. As two separate calls there is a window in which a command that
# exits in milliseconds takes its window — and the whole session — down with it: the run
# then reads as `absent`, making "finished" indistinguishable from "never ran" and the
# `#{pane_dead}` liveness test undecidable (design.md → Liveness caveat).
if tmux new-session -d -s "$NAME" "$WRAPPED" \; \
     set-option -w -t "$NAME" remain-on-exit on 2>/dev/null; then
  printf 'tmux-run: status=created name=%s log=%s\n' "$NAME" "$LOG"
  exit 0
fi

if tmux has-session -t "$NAME" 2>/dev/null; then
  # Session-scoped fallback for a tmux too old to accept the window-scoped `-w` form
  # (which would have aborted the command list above, after the create succeeded).
  # Arming an already-armed session is a no-op, so this is safe to run unconditionally
  # on any existing session, and — as before — failing to arm never fails the dispatch.
  # Ownership is the unchanged mutex call: create failed + session exists means someone
  # else owns it, and we report theirs rather than spawning a duplicate.
  tmux set-option -t "$NAME" remain-on-exit on 2>/dev/null || true
  # Classify: any dead pane (command finished, session kept by remain-on-exit) => dead.
  dead="$(tmux list-panes -t "$NAME" -F '#{pane_dead}' 2>/dev/null | head -1)"
  if [ "$dead" = 1 ]; then st="exists-dead"; else st="exists-alive"; fi
  printf 'tmux-run: status=%s name=%s log=%s\n' "$st" "$NAME" "$LOG"
  if [ -f "$LOG" ]; then
    echo "--- last $TAIL_LINES lines of $LOG ---"
    tail -n "$TAIL_LINES" "$LOG" 2>/dev/null || true
  else
    echo "(log not present yet: $LOG)"
  fi
  exit 0
fi

die "tmux new-session failed for '$NAME' and no such session exists (tmux error)."
