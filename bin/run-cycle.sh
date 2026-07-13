#!/usr/bin/env bash
# run-cycle.sh — the scheduled entrypoint for the orchestrator loop (Phase 4).
#
# This is what the launchd agent fires (and what `schedule.sh run` triggers by
# hand). It is a thin, side-effecting wrapper around orchestrator-cycle.sh whose
# whole reason to exist is the stuff a bare cron-style call gets wrong:
#
#   1. PATH — launchd starts jobs with a stripped environment; claude (~/.local/bin),
#      gh (homebrew), and the python.org python3 are all OFF the default PATH, so a
#      naive call dies with "command not found" and a 0-byte log. We set a known PATH.
#   2. Usage-limit backoff — the dispatches run on the operator's Claude subscription (no
#      API key), so they draw the SAME 5-hour rolling session limit they use by day. When a
#      dispatch hits it, the result JSON says e.g. "resets 7:40pm"; finalize_dispatch
#      records that epoch to state/usage-reset. We read it here and SKIP the whole
#      cycle while inside an exhausted window — a deferred fire costs nothing and the
#      next one after the reset picks up automatically. (See record_usage_reset.)
#   3. Wake chain — pmset can only hold one recurring wake/day, so each fire arms the
#      NEXT one-off wake (via schedule.sh) before doing anything else, so the chain
#      survives even a deferred/skipped cycle. The launchd `repeat` bootstrap re-seeds
#      it every weeknight if it ever breaks.
#   4. Timestamped logging to logs/cycle.log (launchd's own stdout/stderr also tee here).
#
# Usage: run-cycle.sh [--dry-run] [--no-arm]
#   --dry-run  pass through to orchestrator-cycle.sh (plan only, spends nothing)
#   --no-arm   don't arm the next pmset wake (for foreground/manual runs)
#
# Plan-only vs live is a persistent toggle, not a plist edit: `schedule.sh live` /
# `schedule.sh plan-only` write state/mode, which this script reads on every fire.
# Missing mode = plan-only (we never dispatch for real without an explicit opt-in).
# Precedence: an explicit --dry-run / ORCH_DRY=1 always forces plan-only regardless.
#
# Env: everything orchestrator-cycle.sh reads (CAP, BUDGET, WORKER_BUDGET, …) plus
#   ORCH_DRY=1   force plan-only for this run (a manual override of the toggle)
set -uo pipefail   # NOT -e: a failing cycle must still arm the next wake + log

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. PATH — make the toolchain resolvable under launchd's stripped env. Portable:
# newest python.org framework via glob, both homebrew arches, ~/.local/bin for claude.
PYFW="$(ls -d /Library/Frameworks/Python.framework/Versions/*/bin 2>/dev/null | sort -V | tail -1 || true)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin${PYFW:+:$PYFW}:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ARGS=()
ARM=1
JITTER=0
IS_DRY=0
[ "${ORCH_DRY:-0}" = 1 ] && { ARGS+=(--dry-run); IS_DRY=1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) ARGS+=(--dry-run); IS_DRY=1 ;;
    --no-arm)  ARM=0 ;;
    --jitter)  JITTER=1 ;;   # scheduled fires pass this; manual/dry runs stay immediate
    *) echo "run-cycle: unknown arg $1" >&2; exit 2 ;;
  esac; shift
done
# Max jitter window in seconds (default 30 min). The plist fires 15 min before each
# nominal center, so a uniform 0–30 min sleep lands the cycle within ±15 of center —
# de-syncing us from other hosts' on-the-hour cron jobs so we don't thunder a server.
JITTER_MAX_SECS="${JITTER_MAX_SECS:-1800}"

LOG_DIR="$ORCH/logs"; mkdir -p "$LOG_DIR"
STATE_DIR="$ORCH/state"; mkdir -p "$STATE_DIR"
CYCLE_LOG="$LOG_DIR/cycle.log"
RESET_FILE="$STATE_DIR/usage-reset"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*" | tee -a "$CYCLE_LOG"; }

# Resolve plan-only vs live. An explicit --dry-run / ORCH_DRY=1 already forced
# plan-only above; otherwise the persistent toggle (state/mode, set by
# `schedule.sh live|plan-only`) decides — and a missing/non-"live" value defaults to
# plan-only, so a scheduled fire never dispatches for real without an explicit opt-in.
MODE_FILE="$STATE_DIR/mode"
if [ "$IS_DRY" = 0 ]; then
  MODE=""; [ -f "$MODE_FILE" ] && MODE="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || true)"
  if [ "$MODE" = live ]; then
    say "mode: LIVE — dispatching for real"
  else
    IS_DRY=1; ARGS+=(--dry-run)
    say "mode: plan-only (no spend) — \`schedule.sh live\` to enable dispatch [${MODE:-no mode set}]"
  fi
fi

# 3 (first): keep the wake chain alive BEFORE anything that might exit early, so a
# deferred or failing cycle never strands the schedule. Best-effort; needs no spend.
if [ "$ARM" = 1 ]; then
  "$ORCH/bin/schedule.sh" arm-wake >>"$CYCLE_LOG" 2>&1 \
    && say "armed next wake" || say "warn: could not arm next wake (chain relies on launchd repeat bootstrap)"
fi

# 2. Usage-limit gate — if a prior dispatch parked a reset time in the future, the
# session limit is still exhausted; booting the orchestrator would just 429. Skip.
if [ -s "$RESET_FILE" ]; then
  RESET_EPOCH="$(cut -d' ' -f1 "$RESET_FILE" 2>/dev/null || echo 0)"
  NOW_EPOCH="$(date +%s)"
  if [ "${RESET_EPOCH:-0}" -gt "$NOW_EPOCH" ] 2>/dev/null; then
    WHEN="$(date -r "$RESET_EPOCH" '+%a %H:%M' 2>/dev/null || echo "$RESET_EPOCH")"
    say "DEFERRED — Claude session limit still exhausted; resets $WHEN. No dispatch this cycle."
    exit 0
  fi
  # Reset has passed — clear the stale marker so we don't keep re-reading it.
  rm -f "$RESET_FILE"
fi

# Jitter — sleep a random 0..JITTER_MAX_SECS before dispatching, AFTER the gate so a
# deferred cycle exits instantly instead of sleeping for nothing. caffeinate -i holds
# the Mac awake through the sleep (it only just woke for this slot and would otherwise
# idle-sleep mid-jitter). $RANDOM is fine here — de-sync, not cryptography.
if [ "$JITTER" = 1 ] && [ "$IS_DRY" = 0 ] && [ "${JITTER_MAX_SECS:-0}" -gt 0 ]; then
  J=$(( RANDOM % (JITTER_MAX_SECS + 1) ))
  say "jittering ${J}s (±15m window) before dispatch"
  if command -v caffeinate >/dev/null 2>&1; then caffeinate -i sleep "$J"; else sleep "$J"; fi
fi

say "cycle start ${ARGS[*]:-(live)}"
PRE_RESET="$(cat "$RESET_FILE" 2>/dev/null || true)"
# Capture THIS run's output to a per-run temp (so the session-limit scan below can't
# re-fire on a stale line further up the ever-growing cycle.log), then fold it in.
RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/orch-cycle.XXXXXX")"
# bash 3.2 (macOS /bin/bash, which the plist uses) errors on "${ARGS[@]}" when ARGS is
# empty under set -u — the live-mode case (no --dry-run). The +expansion is the portable
# guard. (Same bash-3.2 empty-array landmine documented for worktree-prune.)
"$ORCH/bin/orchestrator-cycle.sh" ${ARGS[@]+"${ARGS[@]}"} >"$RUN_LOG" 2>&1
rc=$?
cat "$RUN_LOG" >>"$CYCLE_LOG"
say "cycle end (rc=$rc)"

# The headless orchestrator session itself runs on the same subscription and can hit
# the limit; its result lands only in the cycle log (workers/checkers self-record via
# finalize_dispatch). Reuse the shared parser so the gate logic is identical everywhere.
source "$ORCH/bin/dispatch-common.sh"
record_usage_reset "$RUN_LOG"
rm -f "$RUN_LOG"
POST_RESET="$(cat "$RESET_FILE" 2>/dev/null || true)"
[ -n "$POST_RESET" ] && [ "$POST_RESET" != "$PRE_RESET" ] \
  && say "noted session-limit reset at $(echo "$POST_RESET" | cut -d' ' -f2-)"

exit "$rc"
