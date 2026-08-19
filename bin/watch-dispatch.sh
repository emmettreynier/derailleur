#!/usr/bin/env bash
# watch-dispatch.sh — watch dispatched worker(s)/checker(s) to terminal state.
#
# The interactive orchestrator arms this after a real launch-worker/launch-checker
# so it (or a wrapping `Monitor`) learns the instant each dispatch finishes —
# WITHOUT the operator having to say "watch them". The script only DETECTS and
# REPORTS terminal state; routing (offer a checker, surface to the operator,
# re-dispatch) stays the orchestrator's judgment, per the interactive brief.
#
# Terminal state is read from LOCAL signals only — zero GitHub calls per tick:
#   - ledger.md `status` field flips off `dispatched` on session exit, set by
#     finalize_dispatch in dispatch-common.sh:
#       done                  finished AND finalized (deliverables present)
#       incomplete-<reason>   exited cleanly WITHOUT finalizing (waiting / uncommitted /
#                             unpushed / nopr / draft / conflicting / noverdict) —
#                             terminal for this dispatch, but the work isn't finished:
#                             RE-DISPATCH REQUIRED
#       interrupted-<reason>  cut off (ratelimit / budget / error)
#       unknown               no parseable result JSON
#   - a checker additionally writes logs/<slug>-pr-<n>-verdict.json on completion.
#     That file is what gets REPORTED once the dispatch is terminal — it is NOT itself
#     a terminal signal (see "the verdict file is not a finish line" below).
# Silence-is-not-success: it also fires on the incomplete/interrupt/unknown statuses,
# and if a session's pid is dead but its status was never finalized it reports
# `unknown` rather than watching forever.
#
# ── FRESHNESS: whose news is this? (issue #66) ────────────────────────────────
# Both evidence sources outlive the dispatch that produced them, so a watch armed in
# the SAME TURN as `dr launch-*` — which the interactive brief mandates — used to
# report the PREVIOUS dispatch's terminal state within one poll:
#   Race 1 — ledger.md is append-only, so until the launcher's line lands the newest
#     line matching `<slug>#<num>` is the last run's, carrying a terminal status.
#   Race 2 — logs/<slug>-pr-<n>-verdict.json is a fixed path per (slug, PR). #49
#     rotates it to `.prev.json` at dispatch, but the rotation happens INSIDE the
#     launcher, so a watch that polls first still sees the old file (and `mv` preserves
#     mtime, which is what made the stale read invisible).
# So the watch now takes the IDENTITY of the dispatch it was asked to watch and
# refuses older evidence:
#   - `<item>@<pid>` (what the launchers print — the strong form): the ledger line is
#     resolved by that pid, so no other dispatch's line can ever be read as this one's.
#   - no pid: a ledger line counts only if its `dispatched` timestamp is at/after a
#     FLOOR — `--since <ts>` when given, else the watch's own start minus `--grace`
#     seconds (default 120). The grace exists because the launcher's append happens a
#     beat BEFORE the watch arms in the mandated same-turn case, so an exact
#     watch-start floor would reject the very line it is waiting for; the arm-time
#     staleness rule below closes the window the grace opens.
#   - no pid and no `--since`: a line byte-identical to one that was ALREADY terminal
#     when this watch armed is the previous dispatch's news whatever its timestamp
#     says, and never fires. (A re-dispatch appends a new line — different pid and
#     timestamp — and finalize_dispatch rewrites the status in place, so any real
#     progress on THIS dispatch differs from the snapshot.)
#   - a verdict file counts only if its mtime is at/after the resolved line's own
#     `dispatched` timestamp. The rotated `.prev.json` keeps its old mtime and the
#     un-rotated stale file predates the dispatch, so both fall through to the status.
#   - NO MATCHING LINE YET IS NOT TERMINAL. The item stays `arming` (pending) — never
#     resolved off a previous run, never reported `unknown` — bounded by
#     `--arm-timeout` (default 180s), after which it reports `no-dispatch-record`
#     loudly rather than waiting in silence.
# `--dry-run` is the one exception: it is an explicit "what is the state right now?"
# snapshot, not a watch armed on a dispatch, so it applies no default floor (pass
# `--since`/`@pid` there too when you need the guard).
#
# ── The verdict file is not a finish line (issue #66 addendum) ────────────────
# A written verdict used to fire immediately, ahead of the ledger status. Observed on
# derailleur PR #67: the verdict JSON landed, the watch reported `-> pass` and exited —
# while the checker was still alive and `checked-pass` was not applied to the issue for
# another ~7 minutes. Reporting that line verbatim tells the operator a label exists
# that does not. A checker item is therefore terminal only when its ledger status
# reaches a terminal value, or its pid is dead (still `unknown`, never waited out).
# The verdict is still WHAT gets reported once terminal — this changed WHEN the watch
# fires, not what it says.
#
# Prints one line per item the instant it goes terminal, then exits 0 once every
# watched item is terminal. Blocking by design: a wrapping `Monitor` makes it
# non-blocking; the brief's fallback runs it blocking.
#
# Item tokens (slug-qualified so they're unambiguous across repos):
#   <slug>#<issue>[@<pid>]    a worker dispatch   (e.g. derailleur#26@34061)
#   <slug>#pr<n>[@<pid>]      a checker dispatch  (e.g. derailleur#pr30@55448)
#
# Usage:
#   watch-dispatch.sh [--interval N] [--since TS] [--grace N] [--arm-timeout N]
#                     [--dry-run] <item> [<item> ...]
#   watch-dispatch.sh derailleur#26@34061 derailleur#pr30@55448   # race-free form
#   watch-dispatch.sh --dry-run derailleur#pr30                   # snapshot, then exit
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${LEDGER:-$ORCH/ledger.md}"
INTERVAL=15
DRY_RUN=0
SINCE=""
GRACE=120
ARM_TIMEOUT=180
US="$(printf '\037')"   # field separator for item_state (see item_state)

usage() {
  cat >&2 <<'EOF'
usage: watch-dispatch.sh [--interval N] [--since TS] [--grace N] [--arm-timeout N]
                         [--dry-run] <item> [<item> ...]
  <item>  <slug>#<issue>[@<pid>]  (worker, e.g. derailleur#26@34061)
          <slug>#pr<n>[@<pid>]    (checker, e.g. derailleur#pr30@55448)
  @<pid>  the dispatch's pid, as printed by dr launch-worker/launch-checker. The
          strong identity: the ledger line is resolved by it, so no earlier dispatch
          of the same item can be read as this one's state.
  --since TS      ISO8601 (2026-08-19T17:09:58Z) or epoch seconds: ignore any ledger
                  line dispatched before TS (used for items given without a pid).
  --grace N       seconds below the watch's start time to accept when deriving that
                  floor itself (default 120; the launcher's ledger append lands a beat
                  before a same-turn watch arms).
  --arm-timeout N seconds to wait for the watched dispatch's ledger line to appear
                  before reporting `no-dispatch-record` (default 180).
EOF
}

items=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval)    INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
    --since)       SINCE="${2:?--since needs a value}"; shift 2 ;;
    --grace)       GRACE="${2:?--grace needs a value}"; shift 2 ;;
    --arm-timeout) ARM_TIMEOUT="${2:?--arm-timeout needs a value}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "watch-dispatch: unknown flag: $1" >&2; usage; exit 2 ;;
    *)             items+=("$1"); shift ;;
  esac
done

if [ "${#items[@]}" -eq 0 ]; then
  echo "watch-dispatch: no items to watch" >&2
  usage
  exit 2
fi

for pair in "INTERVAL:$INTERVAL" "GRACE:$GRACE" "ARM_TIMEOUT:$ARM_TIMEOUT"; do
  name="${pair%%:*}"; val="${pair#*:}"
  case "$val" in
    ''|*[!0-9]*)
      flag="--$(echo "$name" | tr 'A-Z_' 'a-z-')"
      echo "watch-dispatch: $flag must be a non-negative integer: $val" >&2; exit 2 ;;
  esac
done
[ "$INTERVAL" -gt 0 ] || { echo "watch-dispatch: --interval must be a positive integer: $INTERVAL" >&2; exit 2; }

# --- time / file helpers ------------------------------------------------------
# to_epoch <ISO8601Z|epoch> -> epoch seconds, or empty if unparseable. BSD `date -j -f`
# first (macOS, incl. the bash-3.2 CI runner), GNU `date -d` second.
to_epoch() {
  local ts="${1:-}"
  [ -n "$ts" ] || { printf ''; return 0; }
  case "$ts" in
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$ts"; return 0 ;;             # already epoch seconds
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null \
    || date -u -d "$ts" '+%s' 2>/dev/null \
    || printf ''
}

file_mtime() {  # $1 = path -> mtime in epoch seconds (0 if it can't be read)
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0
}

# --- parse each item into "kind slug num pid" (validates shape) ---------------
kinds=(); slugs=(); nums=(); labels=(); pids=()
for item in "${items[@]}"; do
  slug=""; num=""; kind=""; wpid=""; token="$item"
  case "$token" in
    *@*) wpid="${token##*@}"; token="${token%@*}"
         case "$wpid" in
           ''|*[!0-9]*) echo "watch-dispatch: bad pid in '$item' (want <item>@<pid>)" >&2; exit 2 ;;
         esac ;;
  esac
  case "$token" in
    *'#pr'*) slug="${token%%#pr*}"; num="${token#*#pr}"; kind="checker" ;;
    *'#'*)   slug="${token%%#*}";   num="${token#*#}";   kind="worker"  ;;
    *)       echo "watch-dispatch: bad item '$item' (want <slug>#<issue> or <slug>#pr<n>)" >&2; exit 2 ;;
  esac
  case "$num" in ''|*[!0-9]*) echo "watch-dispatch: bad number in '$item'" >&2; exit 2 ;; esac
  [ -n "$slug" ] || { echo "watch-dispatch: missing slug in '$item'" >&2; exit 2 ; }
  kinds+=("$kind"); slugs+=("$slug"); nums+=("$num"); labels+=("$token"); pids+=("$wpid")
done

# --- the freshness floor ------------------------------------------------------
WATCH_START="$(date -u '+%s')"
FLOOR=""        # empty = no floor (a --dry-run snapshot with no identity supplied)
FLOOR_SRC=""
if [ -n "$SINCE" ]; then
  FLOOR="$(to_epoch "$SINCE")"
  [ -n "$FLOOR" ] || { echo "watch-dispatch: --since must be ISO8601 (2026-08-19T17:09:58Z) or epoch seconds: $SINCE" >&2; exit 2; }
  FLOOR_SRC="--since $SINCE"
elif [ "$DRY_RUN" -eq 0 ]; then
  FLOOR=$((WATCH_START - GRACE))
  FLOOR_SRC="watch start -${GRACE}s"
fi
# The arm-time staleness rule applies only where NO identity was supplied at all: with
# a pid the line is resolved by pid, and with --since the operator asserted the floor.
ARM_RULE=0
[ "$DRY_RUN" -eq 0 ] && [ -z "$SINCE" ] && ARM_RULE=1

# --- ledger helpers -----------------------------------------------------------
item_key() {  # $1=kind $2=slug $3=num -> extended-regex key for this item's lines
  if [ "$1" = "worker" ]; then
    printf '^- #%s \\| [^|]*/%s \\|' "$3" "$2"
  else
    printf '^- check pr#%s \\| [^|]*/%s \\|' "$3" "$2"
  fi
}
ledger_line() {  # $1 = extended-regex key, $2 = pid ("" = any) -> newest match (or empty)
  if [ -n "${2:-}" ]; then
    grep -E "$1" "$LEDGER" 2>/dev/null | grep -E "\| pid $2 \|" | tail -1 || true
  else
    grep -E "$1" "$LEDGER" 2>/dev/null | tail -1 || true
  fi
}
line_field() {   # $1 = line, $2 = field name (status|pid) -> value (or empty)
  echo "$1" | sed -n "s/.*| $2 \\([A-Za-z0-9-][A-Za-z0-9-]*\\).*/\\1/p"
}
line_dispatched() {  # $1 = line -> the `dispatched <ts>` value (or empty)
  echo "$1" | sed -n 's/.*| dispatched \([^ |]*\).*/\1/p'
}

# resolve_line <kind> <slug> <num> <watched-pid> <arm-snapshot> -> the ledger line
# belonging to THE WATCHED DISPATCH, or empty when the only evidence on disk belongs to
# an older one (=> still arming, never terminal).
resolve_line() {
  local kind="$1" slug="$2" num="$3" wpid="$4" arm="$5" line dts de
  line="$(ledger_line "$(item_key "$kind" "$slug" "$num")" "$wpid")"
  if [ -z "$line" ]; then printf ''; return 0; fi
  if [ -n "$wpid" ]; then printf '%s' "$line"; return 0; fi   # pid IS the identity
  if [ -n "$FLOOR" ]; then
    dts="$(line_dispatched "$line")"
    de="$(to_epoch "$dts")"
    if [ -z "$de" ] || [ "$de" -lt "$FLOOR" ]; then printf ''; return 0; fi
  fi
  if [ -n "$arm" ] && [ "$line" = "$arm" ]; then printf ''; return 0; fi
  printf '%s' "$line"
}

# terminal_note <terminal-value> <kind> <fresh-verdict?> <verdict> -> " (hint)" for a
# status the operator must act on, else nothing. `incomplete-*` is terminal for THIS
# dispatch but the work isn't done — without the hint it reads like any other finish
# (issue #40).
#
# `incomplete-waiting` on a CHECKER whose verdict file already parses is the one case
# where the status alone underreports: the verdict is real and usable, and the thing
# that still needs reconciling is the live tmux session in that worktree. Name both.
# A missing/unparseable/STALE verdict falls through to the plain hint — silently, since
# a checker that wrote nothing is the ordinary case here.
#
# `unknown` (pid dead, never finalized) with this dispatch's verdict already on disk is
# the crash-after-writing case: the verdict is real but nothing published it, so say so
# rather than letting the bare `unknown` imply the checker produced nothing.
terminal_note() {
  local t="${1:-}" kind="${2:-}" vfresh="${3:-0}" v="${4:-}"
  case "$t" in
    incomplete-waiting)
      if [ "$kind" = "checker" ] && [ "$vfresh" = 1 ] && [ -n "$v" ]; then
        printf ' (verdict %s already written; tmux session alive — reconcile before dispatching into that worktree)' "$v"
        return 0
      fi
      printf ' (re-dispatch required)' ;;
    incomplete-*) printf ' (re-dispatch required)' ;;
    unknown)
      if [ "$kind" = "checker" ] && [ "$vfresh" = 1 ] && [ -n "$v" ]; then
        printf ' (verdict %s written, but the dispatch never finalized — the label/comment may be missing)' "$v"
      fi ;;
  esac
  return 0
}

# item_state <kind> <slug> <num> <watched-pid> <arm-snapshot>
#   -> "<state><US><value><US><note>", state ∈ terminal | pending | arming
# Fields are separated by US (\037), NOT tab: tab is IFS whitespace, so bash's `read`
# collapses a run of them and an empty <value> would silently shift <note> into it.
item_state() {
  local kind="$1" slug="$2" num="$3" wpid="$4" arm="$5"
  local line st lpid de m verdict vfresh=0 v=""
  line="$(resolve_line "$kind" "$slug" "$num" "$wpid" "$arm")"
  if [ -z "$line" ]; then printf 'arming%s%s' "$US" "$US"; return 0; fi
  st="$(line_field "$line" status)"
  lpid="$(line_field "$line" pid)"
  de="$(to_epoch "$(line_dispatched "$line")")"
  if [ "$kind" = "checker" ]; then
    verdict="$ORCH/logs/${slug}-pr-${num}-verdict.json"
    if [ -f "$verdict" ]; then
      m="$(file_mtime "$verdict")"
      # Fresh = written at/after this dispatch started. A rotated `.prev.json` keeps its
      # old mtime and an un-rotated predecessor predates the dispatch, so both are stale.
      if [ -z "$de" ] || [ "$m" -ge "$de" ]; then
        vfresh=1
        v="$(jq -r '.verdict // empty' "$verdict" 2>/dev/null || true)"
      fi
    fi
  fi
  case "$st" in
    ''|dispatched)
      # A written verdict is NOT terminal on its own: the checker still has the
      # comment/label/PR flip ahead of it (issue #66 addendum). Only a dead pid ends it.
      if [ -n "$lpid" ] && [ "$lpid" != "-" ] && ! kill -0 "$lpid" 2>/dev/null; then
        printf 'terminal%sunknown%s%s' "$US" "$US" "$(terminal_note unknown "$kind" "$vfresh" "$v")"
      elif [ "$vfresh" = 1 ] && [ -n "$v" ]; then
        printf 'pending%s%s (verdict %s written; dispatch not finalized yet)' "$US" "$US" "$v"
      else
        printf 'pending%s%s' "$US" "$US"
      fi ;;
    done)
      # The verdict is what gets REPORTED once terminal — for a checker that finalized,
      # its own verdict is the outcome; a worker (or a checker whose verdict predates
      # this dispatch) reports the status.
      if [ "$kind" = "checker" ] && [ "$vfresh" = 1 ]; then
        # A file that exists but carries no parseable `.verdict` still means the checker
        # wrote something this dispatch — report it as such rather than as a bare `done`.
        printf 'terminal%s%s%s' "$US" "${v:-verdict-written}" "$US"
      else
        printf 'terminal%s%s%s' "$US" "$st" "$US"
      fi ;;
    *)
      printf 'terminal%s%s%s%s' "$US" "$st" "$US" "$(terminal_note "$st" "$kind" "$vfresh" "$v")" ;;
  esac
}

# --- arm-time snapshot: what the evidence said BEFORE we started watching -----
# Recorded per item only under the arm-rule (no pid, no --since): the newest matching
# line, and only when it was ALREADY terminal — that is precisely the line a same-turn
# watch must never mistake for this dispatch's news.
n="${#items[@]}"
arm_lines=()
i=0
while [ "$i" -lt "$n" ]; do
  snap=""
  if [ "$ARM_RULE" -eq 1 ] && [ -z "${pids[$i]}" ]; then
    snap="$(ledger_line "$(item_key "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}")" "")"
    st0="$(line_field "$snap" status)"
    case "$st0" in
      ''|dispatched) snap="" ;;   # not terminal at arm time: nothing to suppress
    esac
  fi
  arm_lines+=("$snap")
  i=$((i + 1))
done

# --- dry-run: one snapshot, then exit ----------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "watch-dispatch: --dry-run snapshot of $n item(s) (interval ${INTERVAL}s):"
  i=0
  while [ "$i" -lt "$n" ]; do
    IFS="$US" read -r state value note <<EOF
$(item_state "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}" "${pids[$i]}" "${arm_lines[$i]}")
EOF
    [ "$state" = "terminal" ] || value="$state"
    echo "  ${labels[$i]} (${kinds[$i]}) -> ${value}${note:-}"
    i=$((i + 1))
  done
  exit 0
fi

# --- watch loop: emit per item on terminal, exit when all terminal -----------
echo "watch-dispatch: watching $n item(s) every ${INTERVAL}s: ${labels[*]}"
ids=""
i=0
while [ "$i" -lt "$n" ]; do
  if [ -n "${pids[$i]}" ]; then ids="$ids ${labels[$i]}=pid ${pids[$i]}"; fi
  i=$((i + 1))
done
if [ -n "$FLOOR" ]; then
  echo "watch-dispatch: freshness floor $FLOOR ($FLOOR_SRC) — evidence from an earlier dispatch is ignored;${ids:- no pids supplied}"
fi

fired=(); armed=()
i=0
while [ "$i" -lt "$n" ]; do fired+=(0); armed+=(0); i=$((i + 1)); done
remaining="$n"
while [ "$remaining" -gt 0 ]; do
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${fired[$i]}" -eq 0 ]; then
      IFS="$US" read -r state value note <<EOF
$(item_state "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}" "${pids[$i]}" "${arm_lines[$i]}")
EOF
      case "$state" in
        terminal) : ;;
        arming)
          # No line for THIS dispatch yet. Bounded wait, then say so loudly — an armed
          # watch must never resolve off a previous run, and must never wait in silence.
          if [ "$(( $(date -u '+%s') - WATCH_START ))" -gt "$ARM_TIMEOUT" ]; then
            state="terminal"
            if [ "${armed[$i]}" -eq 1 ]; then
              value="record-gone"
              note=" (this dispatch's ledger line disappeared mid-watch — pruned? check $LEDGER)"
            else
              value="no-dispatch-record"
              note=" (no ledger line for this dispatch after ${ARM_TIMEOUT}s — the launch may have failed; if you armed this watch on an EARLIER dispatch, pass @<pid> or --since)"
            fi
          fi ;;
        pending) armed[$i]=1 ;;
      esac
      if [ "$state" = "terminal" ]; then
        echo "${labels[$i]} (${kinds[$i]}) -> ${value}${note:-}"
        fired[$i]=1
        remaining=$((remaining - 1))
      fi
    fi
    i=$((i + 1))
  done
  [ "$remaining" -gt 0 ] && sleep "$INTERVAL"
done
echo "watch-dispatch: all $n item(s) terminal"
