#!/usr/bin/env bash
# schedule.sh — install / manage the launchd schedule that drives the orchestrator
# loop unattended (Phase 4), plus the pmset wake chain that lets it fire overnight on
# a laptop. The plist TEMPLATE is host/LaunchAgents/orchestrator.plist (version-controlled,
# with @ORCH@/@LABEL@/@HOME@ placeholders); `install` renders it — stamping in the current
# repo path, the operator's launchd LABEL (from orchestrator.conf), and HOME — into
# ~/Library/LaunchAgents/<LABEL>.plist per the portability model. Because launchd
# needs an absolute path baked into the plist, moving the repo means re-running
# `install`; `status` diffs the installed plist against a fresh render and flags drift.
#
# Commands:
#   install     render the plist (stamping in the current repo path), bootstrap-load it,
#               seed the wake chain. Idempotent; re-run after moving the repo.
#   uninstall   bootout the agent, remove the rendered plist, cancel pmset wakes.
#   status      agent loaded? current mode, next wake, usage-reset gate, cycle.log tail.
#   live        flip mode to LIVE (scheduled cycles dispatch for real / spend).
#   plan-only   flip mode to PLAN-ONLY (cycles run but spend nothing). [aliases: dry, plan]
#   pause       stop the timer firing without uninstalling (e.g. while away). REFUSES
#               if a worker/checker is still in-flight (bootout would SIGTERM the whole
#               job tree, reaping them — issue #18); `pause --force` overrides and kills.
#   resume      start firing again after a pause.
#   run         fire one cycle right now, inline + immediate (no jitter); RESPECTS mode.
#   run --dry-run   force a free planning cycle now regardless of mode.
#   arm-wake    (internal) schedule the NEXT pmset wake from the slot list. run-cycle.sh
#               calls this every fire so the chain self-perpetuates; safe to run by hand.
#
# Mode (live vs plan-only) is a persistent toggle in state/mode that run-cycle.sh reads
# on every fire — no plist edit, no reload. Default (no file) = plan-only, so a fresh
# install never dispatches for real until you run `live`.
#
# Why a wake chain: `pmset repeat` holds only ONE recurring wake/day, but the schedule
# wants several nightly slots. So each fire arms the next single wake (`pmset schedule`),
# and `install` seeds `pmset repeat` as a daily bootstrap that re-enters the chain if it
# ever lapses. Wake != run: pmset wakes the Mac ~ a slot time; launchd then fires the job.
set -uo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ORCH/bin/config-common.sh"   # LAUNCHD_LABEL (+ other operator identity)
LABEL="$LAUNCHD_LABEL"
# The tracked template has a fixed, identity-free name; schedule.sh stamps the
# operator's LABEL (and repo path + HOME) into the copy it installs.
PLIST_SRC="$ORCH/host/LaunchAgents/orchestrator.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
MODE_FILE="$ORCH/state/mode"   # "live" -> dispatch for real; anything else/absent -> plan-only
LEDGER="$ORCH/ledger.md"       # in-flight dispatches (worker/checker) — see live_dispatches

# Dispatch FIRE times (24h, local) — the SINGLE source of truth for the schedule, read
# from orchestrator.conf's SCHEDULE_SLOTS. This one list drives BOTH the pmset wake
# chain (wake ~ each fire) AND the plist's StartCalendarInterval (the actual fire), so
# the two can never desync. Default: night-heavy, 15 min before centers 20/23/02/05/08;
# run-cycle.sh's --jitter then sleeps 0–30 min so each cycle lands within ±15 of its
# center (de-syncs us from other hosts' on-the-hour cron — no synchronized stampede).
: "${SCHEDULE_SLOTS:=19:45 22:45 01:45 04:45 07:45}"
# shellcheck disable=SC2206  # intentional word-split into an array of HH:MM slots
SLOTS=($SCHEDULE_SLOTS)

die() { echo "schedule: $*" >&2; exit 1; }

# live_dispatches — echo the ledger lines for dispatches that are STILL RUNNING (status
# `dispatched` AND a recorded pid that is still alive). These are the workers/checkers a
# `launchctl bootout` of this job would SIGTERM: a dispatch the autonomous cycle spawned
# lives inside this launchd job's process tree, and bootout tears down the whole tree.
# The per-dispatch os.setsid() isolation (run_in_new_session) shields a worker from a
# process-GROUP signal when its dispatching session ends, but NOT from launchd killing
# the job — so pausing mid-flight reaps live work (issue #18). A pid of "-" (foreground /
# operator-supervised) can't be signal-tested and isn't the reaping concern, so it's
# skipped. Best-effort and conservative: it may also flag hand-launched detached workers
# (indistinguishable from the ledger), which is a safe over-warning, not a miss.
live_dispatches() {
  [ -f "$LEDGER" ] || return 0
  local line pid status
  while IFS= read -r line; do
    case "$line" in "- #"*|"- check pr#"*) ;; *) continue ;; esac
    status="$(sed -nE 's/.*status[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$line")"
    [ "$status" = dispatched ] || continue
    pid="$(sed -nE 's/.*pid[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$line")"
    [ -n "$pid" ] && [ "$pid" != "-" ] || continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$line"
  done < "$LEDGER"
}

# Fail loud on a malformed schedule rather than silently rendering a broken plist.
validate_slots() {
  [ "${#SLOTS[@]}" -ge 1 ] \
    || die "SCHEDULE_SLOTS is empty — set at least one 24h HH:MM slot in orchestrator.conf"
  local s
  for s in "${SLOTS[@]}"; do
    [[ "$s" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
      || die "SCHEDULE_SLOTS: '$s' is not a valid zero-padded 24h HH:MM time (e.g. 09:30, 23:45)"
  done
}
validate_slots

# plist_calendar_block — emit one <dict> StartCalendarInterval entry per slot, indented
# to sit inside the template's <array>. 10#$x forces base-10 so a zero-padded "08"/"09"
# isn't misread as invalid octal; %d then drops the leading zero for a clean integer.
plist_calendar_block() {
  local s h m
  for s in "${SLOTS[@]}"; do
    h="${s%%:*}"; m="${s##*:}"
    printf '    <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' \
      "$((10#$h))" "$((10#$m))"
  done
}

# Render the plist template to stdout: stamp in the repo path (@ORCH@), the operator's
# launchd label (@LABEL@), and HOME (@HOME@) so a labmate's install is fully their own,
# then expand the @CALENDAR_INTERVAL@ marker into the slot-derived <dict> entries.
render_plist() {
  # Pass the multi-line block through the environment, not `awk -v`: the macOS (BWK)
  # awk rejects a -v value that contains newlines ("newline in string"). Export it in a
  # subshell so it reaches awk (a `VAR=… cmd` prefix binds only the first pipeline stage)
  # without leaking into the caller.
  (
    export CAL_BLOCK; CAL_BLOCK="$(plist_calendar_block)"
    sed -e "s#@ORCH@#$ORCH#g" -e "s#@LABEL@#$LABEL#g" -e "s#@HOME@#$HOME#g" "$PLIST_SRC" \
      | awk '/^[[:space:]]*@CALENDAR_INTERVAL@[[:space:]]*$/ { print ENVIRON["CAL_BLOCK"]; next } { print }'
  )
}

# next_slot_epoch — soonest upcoming slot strictly after now (today or tomorrow).
next_slot_epoch() {
  SLOTS_CSV="$(IFS=,; echo "${SLOTS[*]}")" python3 - <<'PY'
import os, time
slots = os.environ["SLOTS_CSV"].split(",")
now = time.time()
best = None
for off in (0, 1):                       # today, then tomorrow
    for s in slots:
        h, m = map(int, s.split(":"))
        n = time.localtime(now + off*86400)
        e = time.mktime(time.struct_time(
            (n.tm_year, n.tm_mon, n.tm_mday, h, m, 0, n.tm_wday, n.tm_yday, -1)))
        if e > now + 60 and (best is None or e < best):   # +60s guard: not "right now"
            best = e
    if best:
        break
print(int(best))
PY
}

cmd_arm_wake() {
  command -v pmset >/dev/null || { echo "no pmset — skip wake arm"; return 0; }
  local epoch; epoch="$(next_slot_epoch)"
  # pmset wants "MM/dd/yyyy HH:mm:ss"; wake a touch BEFORE the slot so the Mac is up
  # when launchd fires (cold wake takes a few seconds).
  local when; when="$(date -r "$((epoch - 120))" '+%m/%d/%Y %H:%M:%S')"
  # One-off wakeorpoweron. Best-effort: needs power + may prompt for sudo interactively.
  if sudo -n pmset schedule wakeorpoweron "$when" 2>/dev/null; then
    echo "next wake armed: $when"
  else
    echo "warn: could not arm pmset wake (need 'sudo' once; run: sudo $0 arm-wake). Falling back to 'pmset repeat'."
  fi
}

cmd_install() {
  [ -f "$PLIST_SRC" ] || die "plist template missing: $PLIST_SRC"
  command -v launchctl >/dev/null || die "launchctl not found (not macOS?)"
  mkdir -p "$HOME/Library/LaunchAgents" "$ORCH/logs" "$ORCH/state"
  # Render into a tmp file, then mv into place: mv/rename() replaces the destination
  # entry itself rather than following it, so this is safe even if PLIST_DST is a
  # leftover symlink from a pre-templating install (writing through it with a plain
  # '>' would instead truncate the in-repo template it points at).
  render_plist > "$PLIST_DST.tmp" && mv "$PLIST_DST.tmp" "$PLIST_DST"
  echo "rendered $PLIST_DST from $PLIST_SRC (repo path: $ORCH)"
  # bootout any prior copy, then bootstrap the current one (modern launchctl verbs).
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST" \
    && echo "agent bootstrapped: $LABEL" \
    || die "launchctl bootstrap failed (check the plist with: plutil -lint $PLIST_DST)"
  # Seed pmset: a daily 'repeat' bootstrap (re-enters the chain if it lapses) at the
  # FIRST nightly slot, plus arm the immediate next one-off wake.
  if command -v pmset >/dev/null; then
    local first="${SLOTS[0]}"
    if sudo -n pmset repeat wakeorpoweron MTWRF "$first:00" 2>/dev/null; then
      echo "pmset repeat wake seeded: weekdays $first"
    else
      echo "note: run 'sudo pmset repeat wakeorpoweron MTWRF $first:00' once to enable overnight wakes (needs sudo + power)."
    fi
    cmd_arm_wake
  fi
  local mode=""; [ -f "$MODE_FILE" ] && mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || true)"
  if [ "$mode" = live ]; then
    echo "done. Mode is currently LIVE — scheduled runs dispatch for real."
  else
    echo "done. Mode is currently PLAN-ONLY — scheduled runs print what they would do but spend nothing."
    echo "      When ready to let it work for real:  $0 live   (flip back any time with: $0 plan-only)"
  fi
}

# --- mode toggle (plan-only vs live) -----------------------------------------
# The mode is a one-word state file run-cycle.sh reads on every fire — no plist edit,
# no reload, takes effect on the next scheduled run. Default (no file) = plan-only.
cmd_live() {
  mkdir -p "$(dirname "$MODE_FILE")"
  echo live > "$MODE_FILE"
  echo "mode -> LIVE. Scheduled (and manual '$0 run') cycles now dispatch for real."
  launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 \
    || echo "note: the timer isn't installed yet — run '$0 install' so cycles actually fire."
}
cmd_plan_only() {
  mkdir -p "$(dirname "$MODE_FILE")"
  echo plan-only > "$MODE_FILE"
  echo "mode -> PLAN-ONLY. Scheduled cycles will run but spend nothing (they only print what they would do)."
}

# --- pause / resume (stop firing entirely, e.g. while away) -------------------
# Lighter than uninstall: leaves the symlink + pmset wakes in place so 'resume' is
# instant and sudo-free. The Mac may still wake at slot times and find nothing to run
# (harmless — it just sleeps again); for a long absence, 'uninstall' also clears those.
cmd_pause() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  # Guard against reaping in-flight work: `launchctl bootout` SIGTERMs this job's whole
  # process tree, which includes any worker/checker the autonomous cycle dispatched (the
  # os.setsid() isolation doesn't survive a bootout of the job itself — issue #18). If a
  # dispatch is still live, refuse the pause unless --force so the operator doesn't
  # silently kill in-progress work; --force pauses anyway and warns what it's killing.
  local live; live="$(live_dispatches)"
  if [ -n "$live" ]; then
    local n; n="$(printf '%s\n' "$live" | grep -c .)"
    if [ "$force" = 0 ]; then
      echo "schedule: refusing to pause — bootout would SIGTERM $n in-flight dispatch(es) in this job:" >&2
      printf '%s\n' "$live" | sed 's/^/  /' >&2
      echo "  Wait for them to finish (watch: $0 status), or force the pause (KILLS them + loses in-progress work): $0 pause --force" >&2
      exit 1
    fi
    echo "⚠ --force: pausing with $n live dispatch(es) — bootout will SIGTERM them; any unpushed in-progress work is lost." >&2
  fi
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null \
    && echo "paused — timer unloaded; it won't fire until '$0 resume'. (Symlink + wakes left in place.)" \
    || echo "already paused (timer not loaded)."
}
cmd_resume() {
  [ -f "$PLIST_DST" ] || die "no installed plist to resume — run '$0 install' first."
  launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST" \
    && echo "resumed — timer loaded; next fire at the upcoming slot." \
    || echo "already running (timer loaded)."
}

cmd_uninstall() {
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null && echo "agent booted out" || echo "agent not loaded"
  [ -L "$PLIST_DST" -o -f "$PLIST_DST" ] && rm -f "$PLIST_DST" && echo "removed $PLIST_DST"
  if command -v pmset >/dev/null; then
    sudo -n pmset repeat cancel 2>/dev/null && echo "pmset repeat cancelled" || echo "note: 'sudo pmset repeat cancel' to clear the recurring wake."
  fi
  echo "done."
}

cmd_status() {
  echo "== launchd =="
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "loaded: $LABEL"
    launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
      | grep -E 'state =|last exit code =|runs =' | sed 's/^/  /'
  else
    echo "NOT loaded (run: $0 install)"
  fi
  local plist_state="absent"
  if [ -f "$PLIST_DST" ]; then
    if [ -f "$PLIST_SRC" ] && diff -q <(render_plist) "$PLIST_DST" >/dev/null 2>&1; then
      plist_state="current"
    else
      plist_state="STALE — repo path changed since last install; run '$0 install' to re-render"
    fi
  fi
  echo "  slots (SCHEDULE_SLOTS): ${SLOTS[*]}   plist: $plist_state"
  echo "== mode =="
  local mode=""; [ -f "$MODE_FILE" ] && mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || true)"
  if [ "$mode" = live ]; then
    echo "  LIVE — scheduled cycles dispatch for real ('$0 plan-only' to pause spending)"
  else
    echo "  PLAN-ONLY — cycles run but spend nothing ('$0 live' to enable dispatch) [${mode:-no mode set, default plan-only}]"
  fi
  echo "== pmset scheduled wakes =="
  pmset -g sched 2>/dev/null | sed 's/^/  /' || echo "  (pmset unavailable)"
  echo "== usage-limit gate =="
  if [ -s "$ORCH/state/usage-reset" ]; then
    local e; e="$(cut -d' ' -f1 "$ORCH/state/usage-reset")"
    if [ "$e" -gt "$(date +%s)" ] 2>/dev/null; then
      echo "  DEFERRING — session limit until $(cut -d' ' -f2- "$ORCH/state/usage-reset")"
    else
      echo "  clear (last reset marker $(cut -d' ' -f2- "$ORCH/state/usage-reset") has passed)"
    fi
  else
    echo "  clear (no active session-limit marker)"
  fi
  echo "== cycle.log (tail) =="
  tail -n 12 "$ORCH/logs/cycle.log" 2>/dev/null | sed 's/^/  /' || echo "  (no cycle.log yet)"
}

# Manual trigger — runs run-cycle.sh inline and IMMEDIATELY (no --jitter, no wake-arm),
# so a hand sweep fires now rather than sleeping the 0–30 min the scheduled path adds.
# It RESPECTS the current mode (live dispatches; plan-only just plans) — same as a
# scheduled fire. Pass --dry-run to force a free preview regardless of mode.
cmd_run() {
  if [ "${1:-}" = "--dry-run" ]; then
    echo "manual planning cycle (inline, no spend)…"
    exec "$ORCH/bin/run-cycle.sh" --dry-run --no-arm
  fi
  echo "running one cycle now (inline, immediate — no jitter; respects current mode)…"
  exec "$ORCH/bin/run-cycle.sh" --no-arm
}

case "${1:-}" in
  install)    cmd_install ;;
  uninstall)  cmd_uninstall ;;
  status)     cmd_status ;;
  run)        shift; cmd_run "$@" ;;
  live)       cmd_live ;;
  plan-only|dry|plan) cmd_plan_only ;;
  pause)      shift; cmd_pause "$@" ;;
  resume)     cmd_resume ;;
  arm-wake)   cmd_arm_wake ;;
  *) echo "usage: $0 {install|uninstall|status|run [--dry-run]|live|plan-only|pause [--force]|resume}" >&2; exit 2 ;;
esac
