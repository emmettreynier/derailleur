#!/usr/bin/env bash
# worktree-prune.sh — reclaim disk by removing worktrees whose work is DONE and
# already captured on GitHub. Deterministic, no LLM. Sibling of ledger-prune.sh:
# ledger-prune drops spent LEDGER lines; this drops spent WORKTREE directories.
#
# A worktree at <worktrees_dir>/issue-N maps to branch `issue-N` in repo R. Once
# that branch's PR is merged, the worktree is a spent derivative — principle #1/#4:
# GitHub is truth, the worktree is disposable, and a re-dispatch trivially recreates
# it from origin if ever needed. So it can be deleted to stop the worktrees dir
# growing without bound.
#
# TWO MODES:
#   * interactive (DEFAULT, when run raw) — list every worktree with its status and
#     disk use, then let you pick which to remove. You can delete ANY of them; risky
#     ones (uncommitted/unpushed/in-flight) require a per-item y/N confirmation.
#   * --auto (what orchestrator-cycle.sh calls) — non-interactive; removes ONLY
#     worktrees that are MERGED + clean + not in-flight. Anything unmerged (even a
#     closed-not-planned issue) is KEPT and reported — auto mode never deletes work
#     that didn't make it onto the default branch. Conservative, like ledger-prune.
#     Auto mode is ALSO the only mode that reaps dead tmux sessions; interactive mode
#     deliberately leaves the tmux server alone (nothing to pick, nothing to confirm).
#
# THE SAFETY INVARIANT (both modes). The one thing a worktree can hold that GitHub
# does NOT is LOCAL state: uncommitted edits, or commits never pushed. That is the
# only thing deletion could lose. Auto mode refuses on any such state outright;
# interactive mode surfaces it and makes you confirm. The authoritative "work is on
# the default branch" signal is GitHub's **merged PR** bit — NOT git ancestry, which
# a squash merge defeats (the merged branch tip is unreachable from main).
#
# AUTO MODE ALSO REAPS DEAD tmux SESSIONS (issue #53) — see reap_tmux_sessions below.
# Same housekeeping instinct, different derivative: a finished `dr tmux-run` job leaves
# its session behind on purpose, and nothing else ever clears it.
#
# Usage: worktree-prune.sh [--auto] [--dry-run] [--force]
#   (no args)  interactive picker (needs a terminal)
#   --auto     non-interactive: remove merged+clean worktrees, report the rest;
#              also kill DEAD derail-* tmux sessions (never a live one)
#   --dry-run  (auto) report what would be removed/reaped; touch nothing
#   --force    (auto) also remove when only leftover UNTRACKED (non-gitignored)
#              files are in the way — still NEVER when there are uncommitted tracked
#              edits or unpushed commits. (Interactive mode confirms per-item instead.)
#              --force has NO effect on tmux sessions: a live one is never killed.
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${LEDGER:-$ORCH/ledger.md}"

# tmux_job_state (alive|dead|absent, keyed off `#{pane_dead}`) lives in
# dispatch-common.sh. Sourced rather than reimplemented so the reaper's liveness probe
# can never drift from the one the dispatch loop itself trusts — a probe that drifts
# toward "looks finished" is exactly how this would start killing live compute.
# dispatch-common.sh is pure function definitions; sourcing it has no side effects and
# it declares no name this script uses.
. "$ORCH/bin/dispatch-common.sh"

MODE=interactive; DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --auto)        MODE=auto ;;
    --interactive|-i) MODE=interactive ;;
    --dry-run)     DRY=1 ;;
    --force)       FORCE=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# manifest scalar reader (same idiom as launch-worker.sh / orchestrator-cycle.sh)
yml() { sed -nE "s/^$2:[[:space:]]*(.+)/\1/p" "$1" \
          | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
expand() { eval echo "$1"; }   # ~ and $VAR expansion for path fields

# ---------------------------------------------------------------------------
# compute_status <repo> <working_clone> <wt> <branch> <num>
# Sets globals describing one worktree:
#   ST_MERGED (0/1) ST_MERGED_PR  ST_ISTATE  ST_LIVE (0/1)
#   ST_DIRTY (porcelain of tracked edits; empty == clean)  ST_AHEAD  ST_UNTRACKED
#   ST_SAFE (0/1: auto-removable — merged, clean, pushed, not live, untracked-ok)
#   ST_REASON (human-readable status)
# ---------------------------------------------------------------------------
compute_status() {
  local repo="$1" wt="$3" branch="$4" num="$5"
  ST_MERGED=0; ST_MERGED_PR=""; ST_ISTATE=""; ST_LIVE=0
  ST_DIRTY=""; ST_AHEAD=""; ST_UNTRACKED=0; ST_SAFE=0; ST_REASON=""

  grep -qE "^- #$num[[:space:]]*\|[[:space:]]*$repo([[:space:]]|\|)" "$LEDGER" 2>/dev/null && ST_LIVE=1

  ST_MERGED_PR="$(gh pr list -R "$repo" --head "$branch" --state merged --json number -q '.[0].number // empty' 2>/dev/null || true)"
  [ -n "$ST_MERGED_PR" ] && ST_MERGED=1

  ST_ISTATE="$(gh issue view "$num" -R "$repo" --json state -q .state 2>/dev/null || echo '?')"
  ST_DIRTY="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null || echo '?')"

  if git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    ST_AHEAD="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
  else
    ST_AHEAD="no-upstream"
  fi
  ST_UNTRACKED="$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null | grep -c '^??' || true)"
  ST_UNTRACKED=${ST_UNTRACKED:-0}

  # Derive reason + auto-safety. Order matters: in-flight and local-only state win
  # over "merged" (those would lose work / yank an active worktree).
  if [ "$ST_LIVE" = 1 ]; then
    ST_REASON="in-flight (live ledger entry)"
  elif [ -n "$ST_DIRTY" ]; then
    ST_REASON="UNCOMMITTED edits$( [ "$ST_MERGED" = 1 ] && echo " (merged PR#$ST_MERGED_PR)" || echo ", issue $ST_ISTATE")"
  elif [ "$ST_MERGED" = 1 ] && [[ "$ST_AHEAD" =~ ^[0-9]+$ ]] && [ "$ST_AHEAD" -gt 0 ]; then
    ST_REASON="merged PR#$ST_MERGED_PR but $ST_AHEAD unpushed commit(s)"
  elif [ "$ST_MERGED" = 1 ]; then
    if [ "$ST_UNTRACKED" -gt 0 ]; then
      ST_REASON="merged PR#$ST_MERGED_PR, $ST_UNTRACKED untracked file(s) — needs --force"
      [ "$FORCE" = 1 ] && ST_SAFE=1
    else
      ST_REASON="merged PR#$ST_MERGED_PR, clean"; ST_SAFE=1
    fi
  elif [ "$ST_ISTATE" = CLOSED ]; then
    ST_REASON="issue CLOSED but NOT merged"
  else
    ST_REASON="issue ${ST_ISTATE:-?} — work in progress"
  fi
  # Never leak the exit status of the trailing `[ "$FORCE" = 1 ] && ...` short-circuit:
  # in the merged+untracked+no-force case it evaluates false, which under `set -e`
  # would abort the whole run when this function is called bare from a *_cb.
  return 0
}

# each_worktree <callback> — iterate every issue-N worktree across onboarded
# projects, calling <callback> <repo> <working_clone> <wt> <branch> <num>.
each_worktree() {
  local cb="$1" f repo working_clone worktrees_dir wt branch num
  shopt -s nullglob
  for f in "$ORCH"/projects/*.yml; do
    [ -f "$f" ] || continue
    repo="$(yml "$f" repo)"
    working_clone="$(expand "$(yml "$f" working_clone)")"
    worktrees_dir="$(expand "$(yml "$f" worktrees_dir)")"
    [ -n "$repo" ] && [ -n "$working_clone" ] && [ -d "$worktrees_dir" ] || continue
    git -C "$working_clone" worktree prune 2>/dev/null || true  # drop admin recs for gone dirs
    for wt in "$worktrees_dir"/issue-*; do
      [ -d "$wt" ] || continue
      branch="$(basename "$wt")"; num="${branch#issue-}"
      [[ "$num" =~ ^[0-9]+$ ]] || continue
      "$cb" "$repo" "$working_clone" "$wt" "$branch" "$num"
    done
  done
}

remove_worktree() {  # <working_clone> <wt> <branch> <repo> [force]
  local clone="$1" wt="$2" branch="$3" repo="$4" force="${5:-0}" ok=0
  # Note: NO empty-array expansion here — macOS bash 3.2 treats "${arr[@]}" on an
  # empty array as an unbound-variable error under `set -u`. Branch on the flag instead.
  if [ "$force" = 1 ]; then
    git -C "$clone" worktree remove --force "$wt" 2>/dev/null && ok=1
  else
    git -C "$clone" worktree remove "$wt" 2>/dev/null && ok=1
  fi
  if [ "$ok" = 1 ]; then
    # Drop the now-orphaned local branch too. -D (not -d) because a squash-merged
    # branch fails git's "is it merged" ancestry test even though main has its content.
    git -C "$clone" branch -D "$branch" 2>/dev/null || true
    echo "  removed ${repo##*/} $branch"
    return 0
  fi
  echo "  ⚠ remove refused for $wt (try --force)"; return 1
}

# ===========================================================================
# AUTO MODE — non-interactive; remove merged+clean only.
# ===========================================================================
AUTO_REMOVED=0; AUTO_KEPT=0
auto_cb() {
  compute_status "$@"
  local repo="$1" clone="$2" wt="$3" branch="$4"
  if [ "$ST_SAFE" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      echo "  would remove ${repo##*/} $branch — $ST_REASON"; AUTO_REMOVED=$((AUTO_REMOVED+1)); return
    fi
    if remove_worktree "$clone" "$wt" "$branch" "$repo" "$FORCE"; then
      AUTO_REMOVED=$((AUTO_REMOVED+1)); else AUTO_KEPT=$((AUTO_KEPT+1)); fi
  else
    echo "  keep ${repo##*/} $branch — $ST_REASON"; AUTO_KEPT=$((AUTO_KEPT+1))
  fi
}

# ---------------------------------------------------------------------------
# reap_tmux_sessions — kill DEAD derail-* tmux sessions (auto mode only).
#
# WHY: tmux-run.sh sets `remain-on-exit on` so a FINISHED job's session lingers as a
# dead pane for the next dispatch to inspect (load-bearing — tmux_job_state tells
# 'exists-dead' from 'exists-alive' with it). Nothing ever clears them once they've
# served that purpose, so a worker that exits-to-wait and is never re-dispatched
# leaves its session for the rest of the machine's uptime. Bounded (the tmux server
# dies on reboot) but not free: board-digest.sh walks every session once per digest.
#
# THE SAFETY RULE IS THE WHOLE POINT. An ALIVE session means a worker is legitimately
# waiting on real compute — an R estimation, a simulation — and killing it destroys
# work GitHub does NOT have (exactly the invariant the worktree half protects). So a
# session is reaped iff BOTH hold:
#   1. its name starts with `derail-`  (anything else on this machine is not ours), and
#   2. tmux_job_state says `dead`      (liveness, never "the issue looks finished").
# A live session is reported and left — not even --force kills one.
#
# No tmux on PATH, or no server running, is a clean no-op: this pruner must stay
# useful on a machine that has never run a detached job.
# Sets TMUX_PROBED=1 only when a server actually answered, so the summary line stays
# silent on such a machine instead of printing a meaningless 0/0.
# ---------------------------------------------------------------------------
TMUX_REAPED=0; TMUX_ALIVE=0; TMUX_PROBED=0
reap_tmux_sessions() {
  command -v tmux >/dev/null 2>&1 || return 0
  local names name state
  # No server running => list-sessions fails and says so on stderr; that is a no-op
  # here, not an error, so swallow both.
  names="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
  [ -n "$names" ] || return 0
  TMUX_PROBED=1
  # here-string (NOT a pipe): a `while` on the right of a pipe runs in a subshell under
  # bash 3.2 and the counters below would be lost.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in derail-*) ;; *) continue ;; esac
    state="$(tmux_job_state "$name")"
    if [ "$state" = alive ]; then
      echo "  keep tmux $name — pane alive (a worker is waiting on it)"
      TMUX_ALIVE=$((TMUX_ALIVE+1))
    elif [ "$state" = dead ]; then
      if [ "$DRY" = 1 ]; then
        echo "  would reap tmux $name — pane dead"
      elif tmux kill-session -t "$name" 2>/dev/null; then
        echo "  reaped tmux $name — pane dead"
      else
        echo "  ⚠ kill-session refused for tmux $name"; continue
      fi
      TMUX_REAPED=$((TMUX_REAPED+1))
    fi
    # `absent` (it vanished between the listing and the probe) needs no accounting.
  done <<<"$names"
  return 0
}

run_auto() {
  each_worktree auto_cb
  reap_tmux_sessions
  echo "worktree-prune: removed $AUTO_REMOVED, kept $AUTO_KEPT"
  if [ "$TMUX_PROBED" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      echo "worktree-prune: tmux: would reap $TMUX_REAPED dead derail-* sessions, left $TMUX_ALIVE alive"
    else
      echo "worktree-prune: tmux: reaped $TMUX_REAPED dead derail-* sessions, left $TMUX_ALIVE alive"
    fi
  fi
}

# ===========================================================================
# INTERACTIVE MODE — list, then pick.
# ===========================================================================
declare -a WT_PATH WT_CLONE WT_BRANCH WT_REPO WT_DISP WT_DISK WT_REASON WT_SAFE
gather_cb() {
  compute_status "$@"
  local repo="$1" clone="$2" wt="$3" branch="$4"
  WT_PATH+=("$wt"); WT_CLONE+=("$clone"); WT_BRANCH+=("$branch"); WT_REPO+=("$repo")
  WT_DISP+=("${repo##*/}/$branch")
  WT_DISK+=("$(du -sh "$wt" 2>/dev/null | cut -f1 || echo '?')")
  WT_REASON+=("$ST_REASON"); WT_SAFE+=("$ST_SAFE")
}

# expand_selection <raw> — emit chosen 1-based indices (numbers, "1-3" ranges,
# or "safe" for all auto-safe rows). Ignores anything else.
expand_selection() {
  local n=${#WT_PATH[@]} tok i raw
  raw="${1//,/ }"      # commas -> spaces
  raw="${raw//\"/}"    # strip stray double quotes (the prompt shows quoted examples)
  raw="${raw//\'/}"    # strip stray single quotes
  for tok in $raw; do
    if [ "$tok" = safe ]; then
      for ((i=1;i<=n;i++)); do [ "${WT_SAFE[$((i-1))]}" = 1 ] && echo "$i"; done
    elif [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
      seq "${tok%-*}" "${tok#*-}"
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      echo "$tok"
    fi
  done
}

run_interactive() {
  [ -t 0 ] || { echo "interactive mode needs a terminal; use --auto for non-interactive." >&2; exit 1; }
  echo "Scanning worktrees…" >&2
  each_worktree gather_cb
  local n=${#WT_PATH[@]}
  if [ "$n" -eq 0 ]; then echo "No worktrees found."; return 0; fi

  echo
  printf '  %-3s %-26s %6s  %s\n' '#' 'worktree' 'disk' 'status'
  printf '  %-3s %-26s %6s  %s\n' '---' '--------------------------' '------' '------'
  local i mark
  for ((i=1;i<=n;i++)); do
    mark=$([ "${WT_SAFE[$((i-1))]}" = 1 ] && echo '✓' || echo '·')
    printf '  %-3s %-26s %6s  %s %s\n' "$i" "${WT_DISP[$((i-1))]}" "${WT_DISK[$((i-1))]}" "$mark" "${WT_REASON[$((i-1))]}"
  done
  echo
  echo "  ✓ = safe (merged + clean)   · = removing would need confirmation"
  printf 'Select to remove [e.g.  1 3  or  1-3  or  safe ; Enter to quit]: '
  local sel; read -r sel || sel=""
  [ -z "$sel" ] && { echo "Nothing selected."; return 0; }

  local idx removed=0 chosen
  chosen="$(expand_selection "$sel" | sort -un)"
  for idx in $chosen; do
    [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] 2>/dev/null || { echo "  (skip out-of-range: $idx)"; continue; }
    local j=$((idx-1))
    if [ "${WT_SAFE[$j]}" = 1 ]; then
      remove_worktree "${WT_CLONE[$j]}" "${WT_PATH[$j]}" "${WT_BRANCH[$j]}" "${WT_REPO[$j]}" 0 && removed=$((removed+1))
    else
      # Risky: surface the reason and require explicit confirmation; force the remove
      # (git would refuse) only on a yes.
      printf '  ⚠ %s — %s.\n    Delete anyway (may lose local work)? [y/N]: ' "${WT_DISP[$j]}" "${WT_REASON[$j]}"
      local ans; read -r ans || ans=n
      case "$ans" in
        [yY]*) remove_worktree "${WT_CLONE[$j]}" "${WT_PATH[$j]}" "${WT_BRANCH[$j]}" "${WT_REPO[$j]}" 1 && removed=$((removed+1)) ;;
        *) echo "    skipped ${WT_DISP[$j]}" ;;
      esac
    fi
  done
  echo "worktree-prune: removed $removed of $n."
}

case "$MODE" in
  auto)        run_auto ;;
  interactive) run_interactive ;;
esac
