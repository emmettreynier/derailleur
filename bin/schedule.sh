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
#   status      agent loaded? current mode, next wake, usage-reset gate, cycle.log tail,
#               + which onboarded repos are live vs scheduler-paused (the allow-list).
#   live        flip mode to LIVE (scheduled cycles dispatch for real / spend).
#   plan-only   flip mode to PLAN-ONLY (cycles run but spend nothing). [aliases: dry, plan]
#   enable <slug>   add an onboarded repo to the autonomous-dispatch allow-list
#                   (state/scheduled-repos). While the list is non-empty, ONLY listed
#                   repos dispatch autonomously; empty/absent ⇒ all onboarded repos do.
#   disable <slug>  remove a repo from the allow-list (emptying it restores all-live).
#                   Both gate the AUTONOMOUS loop only — manual launch-*.sh and
#                   interactive /orchestrate keep working on any onboarded repo.
#   pause       stop the timer firing without uninstalling (e.g. while away). DURABLE
#               across reboot/logout (issue #90): writes state/paused, which run-cycle.sh
#               checks and exits on, and `launchctl disable`s the label (persisted by
#               launchd) besides booting it out. REFUSES if a worker/checker is still
#               in-flight (bootout would SIGTERM the whole job tree, reaping them —
#               issue #18); `pause --force` overrides and kills.
#   resume      undo a pause: clear state/paused, `launchctl enable`, bootstrap.
#   run         fire one cycle right now, inline + immediate (no jitter); RESPECTS mode.
#               Deliberately OVERRIDES a pause for that one run (passes --ignore-pause)
#               and says so; the pause itself stays in place.
#   run --dry-run   force a free planning cycle now regardless of mode (also overrides).
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
# The DURABLE pause marker (issue #90). Present => paused, whatever launchd says: a bare
# bootout only unloads the job from the current session, and launchd reloads every plist
# in ~/Library/LaunchAgents at login. run-cycle.sh reads the same path and exits early.
PAUSE_FILE="$ORCH/state/paused"

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

# is_paused — 0 iff the durable pause marker exists. Only ever used in a conditional.
is_paused() { [ -f "$PAUSE_FILE" ]; }
# paused_since — the marker's recorded timestamp (or a placeholder if it's empty).
paused_since() { local t; t="$(head -n 1 "$PAUSE_FILE" 2>/dev/null || true)"; echo "${t:-unknown time}"; }
# launchd_disabled — 0 iff launchd's persistent disabled-services database has our label
# marked disabled (`launchctl disable` writes it; it survives reboot). Best-effort parse:
# the line reads `"<label>" => disabled` (or `=> true` on older releases).
launchd_disabled() {
  launchctl print-disabled "gui/$UID_NUM" 2>/dev/null \
    | grep -F "\"$LABEL\"" | grep -qE '=>[[:space:]]*(disabled|true)'
}

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
  # Paused => install KEEPS the pause (issue #90): the plist is re-rendered so a later
  # `resume` loads the current one, but it is NOT bootstrapped, the launchd disable flag
  # is re-asserted, and pmset wakes are left alone. Only `resume` un-pauses.
  if is_paused; then
    launchctl disable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    echo "PAUSED (since $(paused_since)) — install kept the pause: plist re-rendered but NOT loaded."
    echo "      Run '$0 resume' to load it and start firing again."
    return 0
  fi
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

# --- per-repo autonomous-dispatch allow-list (state/scheduled-repos) ----------
# enable/disable edit the allow-list read by config-common.sh:scheduled_repos, which
# gates the AUTONOMOUS loop only (orchestrator-cycle.sh). Manual launch-*.sh and
# interactive /orchestrate are never affected. Polarity is allow-list-when-set: a
# non-empty file restricts autonomous dispatch to its slugs; empty/absent ⇒ all live.
cmd_enable() {
  local slug="${1:-}"
  [ -n "$slug" ] || die "usage: $0 enable <slug>"
  [ -f "$ORCH/projects/$slug.yml" ] \
    || die "'$slug' is not onboarded (no projects/$slug.yml) — onboard it first (bin/new-project.sh) or check the slug."
  mkdir -p "$(dirname "$SCHEDULED_REPOS_FILE")"
  if scheduled_repos | grep -qxF "$slug"; then
    echo "'$slug' is already in the autonomous-dispatch allow-list."
    return 0
  fi
  echo "$slug" >> "$SCHEDULED_REPOS_FILE"
  echo "enabled '$slug' for autonomous dispatch."
  echo "note: an allow-list is now in effect — ONLY listed repos dispatch autonomously."
  echo "      Others still work via manual launch-*.sh / interactive /orchestrate. See '$0 status'."
}
cmd_disable() {
  local slug="${1:-}"
  [ -n "$slug" ] || die "usage: $0 disable <slug>"
  if [ ! -f "$SCHEDULED_REPOS_FILE" ] || ! grep -qxF "$slug" "$SCHEDULED_REPOS_FILE"; then
    echo "'$slug' is not in the allow-list; nothing to do."
    return 0
  fi
  # Drop the exact slug line, keep the rest. grep -vxF exits 1 when nothing remains;
  # there's no `set -e` here, and `|| true` keeps it explicit.
  local tmp="$SCHEDULED_REPOS_FILE.tmp"
  grep -vxF "$slug" "$SCHEDULED_REPOS_FILE" > "$tmp" || true
  mv "$tmp" "$SCHEDULED_REPOS_FILE"
  # Empty file == absent == all-live: remove it so the "no allow-list" path is taken.
  if scheduled_repos | grep -q .; then
    echo "disabled '$slug' — removed from the autonomous-dispatch allow-list."
  else
    rm -f "$SCHEDULED_REPOS_FILE"
    echo "disabled '$slug' — allow-list now empty; ALL onboarded repos dispatch autonomously again."
  fi
}

# --- pause / resume (stop firing entirely, e.g. while away) -------------------
# Lighter than uninstall: leaves the plist + pmset wakes in place so 'resume' is
# instant and sudo-free. The Mac may still wake at slot times and find nothing to run
# (harmless — it just sleeps again); for a long absence, 'uninstall' also clears those.
#
# DURABLE (issue #90). A bare `launchctl bootout` only unloads the job from the current
# launchd session; the plist stays in ~/Library/LaunchAgents and launchd reloads it at
# the next login, so a reboot silently resumed the loop (observed live, 2026-09-30). Two
# independent layers now hold the pause on disk:
#   1. state/paused — the marker run-cycle.sh checks first and exits on (logging
#      `paused — not running`), so even a job that gets loaded anyway (re-install, manual
#      bootstrap, a launchd quirk) never jitters or dispatches. It is also the one
#      source `status` / `pause` report from.
#   2. `launchctl disable gui/<uid>/<label>` — launchd persists this override across
#      reboots, so the job is not even loaded at login.
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
  # Report from the durable state, never from whether bootout happened to succeed.
  local was_paused=0
  if is_paused; then
    was_paused=1
  else
    mkdir -p "$(dirname "$PAUSE_FILE")"
    date '+%Y-%m-%d %H:%M:%S' > "$PAUSE_FILE" || die "could not write $PAUSE_FILE — NOT paused."
  fi
  # Re-assert both launchd layers even when already paused, so a half-applied pause
  # (e.g. the job was re-bootstrapped by hand) is repaired. Their results are reported
  # as notes, not used to decide the headline.
  local disable_note bootout_note
  if launchctl disable "gui/$UID_NUM/$LABEL" 2>/dev/null; then
    disable_note="launchd disable flag set (persists across reboot)"
  else
    disable_note="warn: 'launchctl disable' failed — relying on $PAUSE_FILE alone"
  fi
  if launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null; then
    bootout_note="timer unloaded from this session"
  else
    bootout_note="timer was not loaded in this session"
  fi
  if [ "$was_paused" = 1 ]; then
    echo "already paused (since $(paused_since); marker $PAUSE_FILE)."
  else
    echo "paused — durable across reboot/logout; it won't fire until '$0 resume'."
  fi
  echo "  $disable_note; $bootout_note. (Plist + wakes left in place.)"
}
cmd_resume() {
  [ -f "$PLIST_DST" ] || die "no installed plist to resume — run '$0 install' first."
  local was_paused=0
  is_paused && was_paused=1
  rm -f "$PAUSE_FILE"
  # enable BEFORE bootstrap: launchd refuses to bootstrap a disabled service.
  launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null \
    || echo "warn: 'launchctl enable' failed — the launchd disable flag may still be set (see '$0 status')." >&2
  if launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST" 2>/dev/null; then
    echo "resumed — pause cleared, timer loaded; next fire at the upcoming slot."
  elif launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    if [ "$was_paused" = 1 ]; then
      echo "resumed — pause cleared; timer was already loaded; next fire at the upcoming slot."
    else
      echo "already running (timer loaded, not paused)."
    fi
  else
    die "pause cleared, but 'launchctl bootstrap' failed and the timer is NOT loaded (check: plutil -lint $PLIST_DST)."
  fi
  return 0
}

cmd_uninstall() {
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null && echo "agent booted out" || echo "agent not loaded"
  [ -L "$PLIST_DST" -o -f "$PLIST_DST" ] && rm -f "$PLIST_DST" && echo "removed $PLIST_DST"
  if command -v pmset >/dev/null; then
    sudo -n pmset repeat cancel 2>/dev/null && echo "pmset repeat cancelled" || echo "note: 'sudo pmset repeat cancel' to clear the recurring wake."
  fi
  is_paused && echo "note: still PAUSED ($PAUSE_FILE kept) — a future '$0 install' stays paused until '$0 resume'."
  echo "done."
}

cmd_status() {
  echo "== launchd =="
  # Four distinct states, the pause read from its DURABLE source (state/paused) rather
  # than inferred from "not loaded" (issue #90).
  local loaded=0 disabled=0
  launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 && loaded=1
  launchd_disabled && disabled=1
  if is_paused; then
    echo "PAUSED since $(paused_since) (durable: $PAUSE_FILE; '$0 resume' to un-pause)"
    if [ "$disabled" = 1 ]; then
      echo "  launchd disable flag: set (job not loaded at login)"
    else
      echo "  launchd disable flag: NOT set — run-cycle.sh still exits on the marker; '$0 pause' re-asserts it"
    fi
    [ "$loaded" = 1 ] && echo "  ⚠ job is loaded anyway — fires will log 'paused — not running' and exit"
  elif [ ! -f "$PLIST_DST" ]; then
    echo "NOT installed (no $PLIST_DST; run: $0 install)"
  elif [ "$loaded" = 1 ]; then
    echo "loaded: $LABEL"
    launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
      | grep -E 'state =|last exit code =|runs =' | sed 's/^/  /'
  else
    echo "installed but NOT loaded, and not paused (run: $0 install, or $0 resume)"
    [ "$disabled" = 1 ] && echo "  ⚠ launchd disable flag is set without a pause marker — '$0 resume' clears it"
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
  echo "== per-repo autonomous dispatch (allow-list) =="
  local onboarded allow s
  onboarded="$(ls "$ORCH/projects/"*.yml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.yml$//' || true)"
  allow="$(scheduled_repos)"
  if [ -z "$onboarded" ]; then
    echo "  (no onboarded repos)"
  elif [ -z "$allow" ]; then
    echo "  no allow-list in effect — ALL onboarded repos dispatch autonomously:"
    for s in $onboarded; do echo "    • $s  (live)"; done
  else
    echo "  allow-list ACTIVE ($SCHEDULED_REPOS_FILE) — only listed repos dispatch autonomously:"
    for s in $onboarded; do
      if grep -qxF "$s" <<<"$allow"; then
        echo "    • $s  (live)"
      else
        echo "    • $s  (excluded — scheduler-paused; manual/interactive dispatch still works)"
      fi
    done
    # Warn about allow-list entries with no manifest (they never dispatch).
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      [ -f "$ORCH/projects/$s.yml" ] || echo "    ⚠ $s  (in allow-list but NOT onboarded — ignored)"
    done <<< "$allow"
  fi
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
#
# A pause (state/paused) is DELIBERATELY overridden here, for this one run only: typing
# `run` is an explicit operator act, unlike a launchd fire. It passes --ignore-pause —
# the only way past run-cycle.sh's pause gate — announces the override, and leaves the
# pause in place for every scheduled fire.
cmd_run() {
  if is_paused; then
    echo "note: scheduler is PAUSED (since $(paused_since)) — overriding for this one manual run; the pause stays in place."
  fi
  if [ "${1:-}" = "--dry-run" ]; then
    echo "manual planning cycle (inline, no spend)…"
    exec "$ORCH/bin/run-cycle.sh" --dry-run --no-arm --ignore-pause
  fi
  echo "running one cycle now (inline, immediate — no jitter; respects current mode)…"
  exec "$ORCH/bin/run-cycle.sh" --no-arm --ignore-pause
}

case "${1:-}" in
  install)    cmd_install ;;
  uninstall)  cmd_uninstall ;;
  status)     cmd_status ;;
  run)        shift; cmd_run "$@" ;;
  live)       cmd_live ;;
  plan-only|dry|plan) cmd_plan_only ;;
  enable)     shift; cmd_enable "$@" ;;
  disable)    shift; cmd_disable "$@" ;;
  pause)      shift; cmd_pause "$@" ;;
  resume)     cmd_resume ;;
  arm-wake)   cmd_arm_wake ;;
  *) echo "usage: $0 {install|uninstall|status|run [--dry-run]|live|plan-only|enable <slug>|disable <slug>|pause [--force]|resume}" >&2; exit 2 ;;
esac
