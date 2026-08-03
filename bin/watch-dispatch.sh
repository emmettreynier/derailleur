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
#   - a checker additionally writes logs/<slug>-pr-<n>-verdict.json on completion
#     (this can appear a beat before the status flip — checked first, unless the
#     status is already incomplete-*, which is the later and more authoritative word).
#     `incomplete-waiting` outranking the verdict file does NOT discard it, though: a
#     verdict already on disk is reported alongside the live session, so the operator
#     sees both facts (issue #40 amendment).
# Silence-is-not-success: it also fires on the incomplete/interrupt/unknown statuses,
# and if a session's pid is dead but its status was never finalized it reports
# `unknown` rather than watching forever.
#
# Prints one line per item the instant it goes terminal, then exits 0 once every
# watched item is terminal. Blocking by design: a wrapping `Monitor` makes it
# non-blocking; the brief's fallback runs it blocking.
#
# Item tokens (slug-qualified so they're unambiguous across repos):
#   <slug>#<issue>    a worker dispatch   (e.g. derailleur#26)
#   <slug>#pr<n>      a checker dispatch  (e.g. derailleur#pr30)
#
# Usage:
#   watch-dispatch.sh [--interval N] [--dry-run] <item> [<item> ...]
#   watch-dispatch.sh derailleur#26 derailleur#pr30
#   watch-dispatch.sh --dry-run derailleur#pr30        # report current state once, exit
set -euo pipefail

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="$ORCH/ledger.md"
INTERVAL=15
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
usage: watch-dispatch.sh [--interval N] [--dry-run] <item> [<item> ...]
  <item>  <slug>#<issue>  (worker, e.g. derailleur#26)
          <slug>#pr<n>    (checker, e.g. derailleur#pr30)
EOF
}

items=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "watch-dispatch: unknown flag: $1" >&2; usage; exit 2 ;;
    *)          items+=("$1"); shift ;;
  esac
done

if [ "${#items[@]}" -eq 0 ]; then
  echo "watch-dispatch: no items to watch" >&2
  usage
  exit 2
fi

case "$INTERVAL" in
  ''|*[!0-9]*) echo "watch-dispatch: --interval must be a positive integer: $INTERVAL" >&2; exit 2 ;;
esac

# --- parse each item into "kind slug num" (validates shape) -------------------
kinds=(); slugs=(); nums=(); labels=()
for item in "${items[@]}"; do
  slug=""; num=""; kind=""
  case "$item" in
    *'#pr'*) slug="${item%%#pr*}"; num="${item#*#pr}"; kind="checker" ;;
    *'#'*)   slug="${item%%#*}";   num="${item#*#}";   kind="worker"  ;;
    *)       echo "watch-dispatch: bad item '$item' (want <slug>#<issue> or <slug>#pr<n>)" >&2; exit 2 ;;
  esac
  case "$num" in ''|*[!0-9]*) echo "watch-dispatch: bad number in '$item'" >&2; exit 2 ;; esac
  [ -n "$slug" ] || { echo "watch-dispatch: missing slug in '$item'" >&2; exit 2 ; }
  kinds+=("$kind"); slugs+=("$slug"); nums+=("$num"); labels+=("$item")
done

# --- helpers ------------------------------------------------------------------
ledger_line() {  # $1 = extended-regex key -> newest matching ledger line (or empty)
  grep -E "$1" "$LEDGER" 2>/dev/null | tail -1 || true
}
line_field() {   # $1 = line, $2 = field name (status|pid) -> value (or empty)
  echo "$1" | sed -n "s/.*| $2 \\([A-Za-z0-9-][A-Za-z0-9-]*\\).*/\\1/p"
}

# terminal_note <terminal-value> <kind> <slug> <num> -> " (hint)" for a status the
# operator must act on, else nothing. `incomplete-*` is terminal for THIS dispatch but
# the work isn't done — without the hint it reads like any other finish (issue #40).
#
# `incomplete-waiting` on a CHECKER whose verdict file already parses is the one case
# where the status alone underreports: the verdict is real and usable, and the thing
# that still needs reconciling is the live tmux session in that worktree. Name both.
# A missing/unparseable verdict falls through to the plain hint — silently, since a
# checker that wrote nothing is the ordinary case here.
terminal_note() {
  local t="${1:-}" kind="${2:-}" slug="${3:-}" num="${4:-}" vfile v
  case "$t" in
    incomplete-waiting)
      vfile="$ORCH/logs/${slug}-pr-${num}-verdict.json"
      if [ "$kind" = "checker" ] && [ -f "$vfile" ]; then
        v="$(jq -r '.verdict // empty' "$vfile" 2>/dev/null || true)"
        if [ -n "$v" ]; then
          printf ' (verdict %s already written; tmux session alive — reconcile before dispatching into that worktree)' "$v"
          return 0
        fi
      fi
      printf ' (re-dispatch required)' ;;
    incomplete-*) printf ' (re-dispatch required)' ;;
  esac
  return 0
}

# Resolve the terminal state of one item, or empty string if not yet terminal.
terminal_state() {  # $1=kind $2=slug $3=num -> prints terminal value or nothing
  local kind="$1" slug="$2" num="$3" key line st pid verdict
  if [ "$kind" = "worker" ]; then
    key="^- #${num} \\| [^|]*/${slug} \\|"
  else
    key="^- check pr#${num} \\| [^|]*/${slug} \\|"
  fi
  line="$(ledger_line "$key")"
  st="$(line_field "$line" status)"
  if [ "$kind" = "checker" ]; then
    verdict="$ORCH/logs/${slug}-pr-${num}-verdict.json"
    # The verdict file normally wins (it can land a beat before the status flip) —
    # EXCEPT when the status is already `incomplete-*`: that is written by
    # finalize_dispatch after the session exited, so it is strictly later news, and it
    # means the launcher judged the verdict missing or unusable.
    case "$st" in
      incomplete-*) : ;;
      *)
        if [ -f "$verdict" ]; then
          jq -r '.verdict // "verdict-written"' "$verdict" 2>/dev/null || echo "verdict-written"
          return 0
        fi ;;
    esac
  fi
  if [ -n "$st" ] && [ "$st" != "dispatched" ]; then
    echo "$st"; return 0
  fi
  # pid dead but status never finalized => unknown (never watch a crash in silence)
  pid="$(line_field "$line" pid)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "unknown"; return 0
  fi
  return 0
}

# --- dry-run: one snapshot, then exit ----------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  n="${#items[@]}"
  echo "watch-dispatch: --dry-run snapshot of $n item(s) (interval ${INTERVAL}s):"
  i=0
  while [ "$i" -lt "$n" ]; do
    t="$(terminal_state "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}")"
    [ -n "$t" ] || t="pending"
    echo "  ${labels[$i]} (${kinds[$i]}) -> $t$(terminal_note "$t" "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}")"
    i=$((i + 1))
  done
  exit 0
fi

# --- watch loop: emit per item on terminal, exit when all terminal -----------
n="${#items[@]}"
echo "watch-dispatch: watching $n item(s) every ${INTERVAL}s: ${labels[*]}"
fired=()
remaining="$n"
while [ "$remaining" -gt 0 ]; do
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${fired[$i]:-0}" -eq 0 ]; then
      t="$(terminal_state "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}")"
      if [ -n "$t" ]; then
        echo "${labels[$i]} (${kinds[$i]}) -> $t$(terminal_note "$t" "${kinds[$i]}" "${slugs[$i]}" "${nums[$i]}")"
        fired[$i]=1
        remaining=$((remaining - 1))
      fi
    fi
    i=$((i + 1))
  done
  [ "$remaining" -gt 0 ] && sleep "$INTERVAL"
done
echo "watch-dispatch: all $n item(s) terminal"
