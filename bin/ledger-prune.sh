#!/usr/bin/env bash
# ledger-prune.sh — drop completed/dead worker entries so the ledger reflects
# only LIVE workers (the basis for the concurrency cap). Deterministic, no LLM.
#
# An entry is pruned when its issue is closed/merged OR its recorded pid is gone.
# CONSERVATIVE: on any uncertainty (gh lookup failed, unknown/"-" pid) the entry
# is KEPT — better to under-count capacity than to double-dispatch.
#
# This is the wake-time housekeeping that the worker's `status` field anticipates
# (Phase 4): workers don't self-update the ledger; the orchestrator prunes here.
#
# THREE PHASES, in this order (issue #63):
#   1. RECONCILE  — every dead-pid entry that never reached a terminal status gets the
#      finalization its own session never ran (see reconcile_dead_dispatches below).
#   2. SWEEP      — every verdict JSON in logs/ that no ledger entry owns is checked for
#      an unapplied routing label and reported.
#   3. PRUNE      — the original drop pass, now downstream of both, so nothing is deleted
#      before the evidence on disk has been read.
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ORCH/bin/config-common.sh"   # GITHUB_HANDLE (escalation @-mention)
# reconciled_status / report_no_clean_finish / verdict_of / verdict_label /
# publish_recovered_verdict — the finalization a killed session never got to run.
source "$ORCH/bin/dispatch-common.sh"
LEDGER="${LEDGER:-$ORCH/ledger.md}"
[ -f "$LEDGER" ] || { echo "ledger-prune: no ledger at $LEDGER (nothing to do)"; exit 0; }

# ── phase 1: reconcile before pruning (issue #63) ─────────────────────────────
# THE HOLE THIS CLOSES. finalize_dispatch runs INSIDE the dispatched session (appended to
# run_in_new_session's trailing `bash -c` chain), so a session killed outright — SIGKILL,
# host sleep, OOM — never reaches it and its line stays at `status dispatched` against a
# pid that is already gone. The prune pass below then dropped that line SILENTLY: its
# "surface a dispatch that did not finish cleanly" branch only fires for a status that
# already startswith interrupted/incomplete, which a still-`dispatched` line never does.
#
# Observed 2026-08-04 on a checker (california-pesticides PR #64, pid 80838): the review
# COMPLETED — a full `pass_with_findings` verdict JSON on disk — but no label was ever
# applied, so the PR never reached the operator's merge gate; the ledger line was pruned
# without a word; and because no `**Checker interrupted:` comment was posted, CHECKER_LIMIT
# never advanced, so the same PR was due to be re-checked at a full CHECKER_BUDGET. The
# label was applied by hand from the JSON. Same false-confidence family as #40/#49/#51/#52,
# but the path where finalize_dispatch never runs AT ALL — so it needs a reconciler outside
# the dispatched process, not another rung inside assert_finalized.
#
# WHAT IT DELIBERATELY DOES NOT DO: `record_usage_reset`. finalize_dispatch parks a
# usage-limit reset for the scheduler when it sees `interrupted-ratelimit`, but that parser
# rolls a "resets 7:40pm" already past today's clock forward to TOMORROW — honest a few
# seconds after the cutoff, and a ~24h deferral of the whole loop when read off a log that
# died at an unknown time in the past. A reconciler is the wrong place to arm it.

# _manifest_field <slug> <key> -> the manifest value, empty when the manifest or key is
# absent. Same reader the launchers use (bin/launch-worker.sh's `yml`), copied rather than
# shared because it is two lines and the launchers bind it to one MANIFEST.
_manifest_field() {
  local mf="$ORCH/projects/$1.yml"
  if [ ! -f "$mf" ]; then printf ''; return 0; fi
  sed -nE "s/^$2:[[:space:]]*(.+)/\1/p" "$mf" \
    | sed -E 's/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//' | head -1
  return 0
}
_expand() { eval echo "$1"; }   # ~ and $VAR expansion for manifest path fields

# _slug_of_log <log-path> -> the project slug encoded in the log basename
# (logs/<slug>-issue-N.log, logs/<slug>-pr-N.log). Empty if it doesn't match.
_slug_of_log() {
  printf '%s' "$(basename "${1:-}")" | sed -nE 's/^(.+)-(issue|pr)-[0-9]+\.log$/\1/p'
  return 0
}

# reconcile_entry <kind> <num> <repo> <branch> <log> <pid> <status> <dispatched-at>
# <dispatched-at> is the line's `dispatched <ts>`; publish_recovered_verdict needs it to tell
# THIS round's verdict comment from a previous round's (issue #63 round 2).
reconcile_entry() {
  local kind="$1" num="$2" repo="$3" branch="$4" log="$5" pid="$6" status="$7" dispatched_at="${8:-}"
  local slug wt wdir st vf v note
  echo "reconciling $kind $repo#$num — pid $pid dead, status still \`$status\` (log: $log)" >&2

  slug="$(_slug_of_log "$log")"
  wt=""
  if [ -n "$slug" ] && [ -n "$branch" ]; then
    wdir="$(_expand "$(_manifest_field "$slug" worktrees_dir)")"
    [ -n "$wdir" ] && wt="$wdir/$branch"
  fi
  vf="${log%.log}-verdict.json"

  # A WORKER's battery is entirely local — uncommitted / unpushed / the branch's PR — so
  # with no worktree there is nothing to read and no honest status to write. Record
  # `unknown` (terminal, so watch-dispatch reports it rather than watching in silence) and
  # say so loudly: that is the "explicit, logged reconciliation failure" the prune pass is
  # allowed to drop. Do NOT post an incomplete comment here — a missing worktree usually
  # means worktree-prune removed a MERGED, clean one, i.e. the work landed, and a countable
  # "did not finish" comment on a landed issue would escalate a success to needs-input.
  # A checker needs none of this: its deliverable is the verdict JSON in logs/, and the repo
  # comes off the ledger line, so it reconciles with no worktree at all.
  if [ "$kind" = "worker" ] && { [ -z "$wt" ] || [ ! -d "$wt" ]; }; then
    _ledger_set_status "$LEDGER" "$pid" "unknown"
    echo "  ⚠ worktree gone (${wt:-<unresolvable>}) — cannot re-run the finalization battery." >&2
    echo "    recorded status unknown; nothing posted. Check the log if the work looks missing: $log" >&2
    return 0
  fi

  st="$(reconciled_status "$kind" "$log" "$wt" "$repo")"
  _ledger_set_status "$LEDGER" "$pid" "$st"
  echo "  reconciled: status $status -> $st" >&2

  # A CHECKER whose verdict parses is the #63 case itself: the review completed, so the
  # LABEL is the outcome and there is no interrupted/incomplete round to report — posting
  # one would say "this round decided nothing" about a review that decided everything.
  # Publishing is gated on the verdict alone, not on `st`: a verdict written before a
  # rate-limit cutoff (or with a detached job still running, so st is incomplete-waiting) is
  # just as complete, and the status stays honest either way for watch-dispatch to report.
  if [ "$kind" = "checker" ]; then
    v="$(verdict_of "$vf")"
    if [ -n "$v" ]; then
      note="$(publish_recovered_verdict "$vf" "$repo" "$num" "" "$dispatched_at")"
      [ -n "$note" ] && echo "  $note" >&2
      return 0
    fi
    echo "  no usable verdict at $vf — this round decided nothing" >&2
  fi
  # Everything else gets exactly what finalize_dispatch would have left: the stranded-commit
  # push and the ONE countable `**Worker/Checker interrupted:|incomplete:` comment, so
  # WORKER_LIMIT / CHECKER_LIMIT finally advance for a death they used to be blind to.
  report_no_clean_finish "$kind" "$st" "$log" "$wt" "$repo" "$num"
  return 0
}

# reconcile_dead_dispatches — walk the ledger and reconcile every entry whose pid is dead
# and whose status never reached a terminal value. A LIVE pid is never touched (the session
# is still working, and finalize_dispatch is still coming); a pid of `-` (a --foreground
# dispatch, whose finalize ran inline under the operator's eye) is unknowable and left
# alone. Python does the parse + the liveness call so the pid semantics match the prune
# pass below EXACTLY — including PermissionError meaning "alive, another user's".
reconcile_dead_dispatches() {
  local targets kind num repo branch log pid status dispatched_at
  targets="$(LEDGER="$LEDGER" python3 <<'RECON'
import os, re
for ln in open(os.environ["LEDGER"]).read().splitlines():
    m = re.match(r"^-\s+(check pr)?#(\d+)\s*\|", ln)
    if not m:
        continue
    kind = "checker" if m.group(1) else "worker"
    fields = [f.strip() for f in ln.split("|")]
    repo   = fields[1] if len(fields) > 1 else ""
    branch = fields[2] if len(fields) > 2 else ""
    log    = fields[3] if len(fields) > 3 else ""
    pid    = (re.search(r"pid\s+(\S+)", ln) or [None, ""])[1] or ""
    status = (re.search(r"status\s+(\S+)", ln) or [None, ""])[1] or ""
    disp   = (re.search(r"dispatched\s+(\S+)", ln) or [None, ""])[1] or ""
    # Terminal statuses are already finalized — nothing to redo.
    if status in ("done", "unknown") or status.startswith(("incomplete", "interrupted")):
        continue
    if pid in ("", "-", "?"):
        continue
    try:
        p = int(pid)
    except ValueError:
        continue
    try:
        os.kill(p, 0)
        continue                 # ALIVE -> hands off, its own finalize is still to come
    except ProcessLookupError:
        pass                     # dead -> reconcile
    except PermissionError:
        continue                 # exists, owned by another user -> treat as alive
    if not repo or not log:
        continue                 # unparseable line: the prune pass warns about it
    print("\t".join([kind, m.group(2), repo, branch, log, pid, status, disp]))
RECON
)"
  [ -n "$targets" ] || return 0
  # The heredoc is on fd 3, not stdin: reconcile_entry shells out to git/gh, and a child
  # that reads stdin would eat the rest of the target list.
  while IFS="$(printf '\t')" read -r kind num repo branch log pid status dispatched_at <&3; do
    [ -n "$kind" ] || continue
    reconcile_entry "$kind" "$num" "$repo" "$branch" "$log" "$pid" "$status" "$dispatched_at"
  done 3<<TARGETS
$targets
TARGETS
  return 0
}

# ── phase 2: sweep logs/ for verdicts no ledger entry owns (issue #63) ────────
# The reconciler above can only fix a dispatch the ledger still remembers. A verdict JSON
# whose line was already dropped — by an older ledger-prune, or by any prune that ran before
# this reconciler existed — is invisible to it, and that is exactly the shape of the observed
# failure: a complete review sitting in logs/, no label, nothing pointing at it. This sweep
# makes that case DETECTABLE.
#
# It REPORTS ONLY, deliberately: with no ledger entry there is no dispatch context (which
# generation, whether a later round superseded it), so applying a label off a file of unknown
# vintage could re-open a PR the operator already handled. Read the warning, then apply it by
# hand or re-check the PR.
#
# Runs BEFORE the prune pass, so "no ledger entry owns it" covers both a still-live entry and
# one this run just reconciled. Two filters keep it signal, not noise — every verdict from
# every checker that ever finished normally also sits in logs/ forever:
#   * the PR must still be OPEN (a merged/closed PR's verdict is moot), and
#   * the closing issue must NOT already carry the label the verdict routes to (i.e. the
#     outcome never landed). A `gh` lookup that fails leaves it unreported — silence on an
#     uncertain network, like the rest of this script.
# Its own dead ends, though, are REPORTED rather than skipped (issue #63 round 2): no manifest
# for the slug, no `gh` on PATH, and a JSON with no `issue` field are all permanent LOCAL
# conditions that never resolve on a later run, so swallowing them would make a detectability
# pass silent about precisely the files it understands least.
# VERDICT_SWEEP_LIMIT bounds the `gh` calls; a truncated sweep says so rather than reading
# as "checked everything".
VERDICT_SWEEP_LIMIT="${VERDICT_SWEEP_LIMIT:-25}"

sweep_unowned_verdicts() {
  local files f key slug pr repo v label issue prstate labs n=0 skipped=0 found=0
  files="$(ls -t "$ORCH"/logs/*-verdict.json 2>/dev/null || true)"   # newest first
  [ -n "$files" ] || return 0
  while IFS= read -r f <&3; do        # fd 3, not stdin — the gh calls below inherit stdin
    [ -n "$f" ] || continue
    key="$(basename "${f%-verdict.json}")"            # <slug>-pr-<n>
    grep -qF "$key.log" "$LEDGER" 2>/dev/null && continue   # a ledger entry owns it
    n=$((n + 1))
    if [ "$n" -gt "$VERDICT_SWEEP_LIMIT" ]; then skipped=$((skipped + 1)); continue; fi
    v="$(verdict_of "$f")"
    if [ -z "$v" ]; then
      echo "⚠ unowned verdict file, unparseable: $f (no ledger entry, no readable verdict)" >&2
      found=$((found + 1)); continue
    fi
    label="$(verdict_label "$v")"
    if [ -z "$label" ]; then
      echo "⚠ unowned verdict file $f carries an unrecognized verdict '$v'" >&2
      found=$((found + 1)); continue
    fi
    slug="${key%-pr-*}"; pr="${key##*-pr-}"
    # The two LOCAL dead ends below are reported, not skipped: this pass exists so that an
    # orphaned verdict is DETECTABLE, and neither condition ever resolves itself on a later
    # run — a bare `continue` would make the sweep permanently silent about exactly the file
    # it can least explain. (A failed/unparseable `gh` lookup further down stays silent by
    # design — that is an uncertain network, which the next cycle re-reads.)
    repo="$(_manifest_field "$slug" repo)"
    if [ -z "$repo" ]; then
      echo "⚠ unowned verdict file $f: no manifest at projects/$slug.yml, so its repo is unknown" >&2
      echo "    — cannot check whether \`$label\` landed. Onboard the slug or delete the file." >&2
      found=$((found + 1)); continue
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "⚠ unowned verdict file $f ($repo#$pr, verdict \`$v\`): gh not on PATH — routing unverifiable" >&2
      found=$((found + 1)); continue
    fi
    prstate="$(gh pr view "$pr" -R "$repo" --json state 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true)"
    [ "$prstate" = "OPEN" ] || continue
    issue="$(jq -r '.issue // empty' "$f" 2>/dev/null || true)"
    if [ -z "$issue" ]; then
      echo "⚠ unowned verdict file $f: verdict \`$v\` on open $repo#$pr, but the JSON names no \`issue\`" >&2
      echo "    — cannot check whether \`$label\` landed on the closing issue. Read the file and route by hand." >&2
      found=$((found + 1)); continue
    fi
    labs="$(gh issue view "$issue" -R "$repo" --json labels 2>/dev/null \
            | jq -r '.labels[].name' 2>/dev/null || true)"
    grep -qxF -- "$label" <<<"$labs" && continue      # the outcome landed — not orphaned
    echo "⚠ UNROUTED VERDICT: $f" >&2
    echo "    verdict \`$v\` on $repo#$pr (closes #$issue) was never routed — #$issue carries no \`$label\`," >&2
    echo "    and no ledger entry owns the dispatch. Apply the label from the JSON, or re-check the PR." >&2
    found=$((found + 1))
  done 3<<FILES
$files
FILES
  if [ "$skipped" -gt 0 ]; then
    echo "ledger-prune: verdict sweep stopped at VERDICT_SWEEP_LIMIT=$VERDICT_SWEEP_LIMIT — $skipped older verdict file(s) NOT checked" >&2
  fi
  [ "$found" -gt 0 ] && echo "ledger-prune: $found unowned verdict file(s) reported above" >&2
  return 0
}

reconcile_dead_dispatches
sweep_unowned_verdicts

# ── phase 3: the prune pass ───────────────────────────────────────────────────

LEDGER="$LEDGER" GITHUB_HANDLE="$GITHUB_HANDLE" python3 <<'PY'
import json, os, re, subprocess, sys

ledger = os.environ["LEDGER"]
lines = open(ledger).read().splitlines()

def _gh_state(kind, repo, num):  # kind = "issue" | "pr"
    try:
        r = subprocess.run(
            ["gh", kind, "view", str(num), "-R", repo, "--json", "state"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return json.loads(r.stdout).get("state")
    except Exception:
        pass
    return None  # unknown -> keep

def issue_closed(repo, num):
    return {"CLOSED": True, None: None}.get(_gh_state("issue", repo, num), False)

def pr_done(repo, num):  # a checker is done once its PR is no longer open
    s = _gh_state("pr", repo, num)
    return None if s is None else s in ("CLOSED", "MERGED")

def pid_dead(pid):
    if not pid or pid in ("-", "?"):
        return None
    try:
        pid = int(pid)
    except ValueError:
        return None
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False  # exists, owned by another user

def issue_labels(repo, num):
    try:
        r = subprocess.run(
            ["gh", "issue", "view", str(num), "-R", repo, "--json", "labels"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return {l["name"] for l in json.loads(r.stdout).get("labels", [])}
    except Exception:
        pass
    return None  # unknown -> don't touch

def has_open_pr(repo, num):
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "-R", repo, "--state", "open", "--json",
             "closingIssuesReferences"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return any(
                ref.get("number") == num
                for pr in json.loads(r.stdout)
                for ref in (pr.get("closingIssuesReferences") or []))
    except Exception:
        pass
    return None  # unknown -> don't touch

def relabel_resume(repo, num):
    try:
        subprocess.run(["gh", "issue", "edit", str(num), "-R", repo,
                         "--add-label", "resume"], capture_output=True, timeout=15)
    except Exception:
        pass

def issue_comments(repo, num):
    try:
        r = subprocess.run(
            ["gh", "issue", "view", str(num), "-R", repo, "--json", "comments"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return json.loads(r.stdout).get("comments", [])
    except Exception:
        pass
    return None  # unknown -> don't touch

# Both no-clean-finish leads finalize_dispatch can post (dispatch-common.sh). Both are
# capped — an exit-to-wait used to be invisible to WORKER_LIMIT entirely, so a wedged
# tmux job re-dispatched every cycle forever (issue #40) — but they are capped
# SEPARATELY, because their retry cost differs by orders of magnitude:
#
#   wait class   `**Worker incomplete: incomplete-waiting` — a babysit handoff. The
#                brief TELLS the worker to exit while a detached tmux job runs; the
#                retry reattaches, sees the job running, and exits again for cents.
#                Loose cap (WORKER_WAIT_LIMIT) so legitimate multi-session progress on
#                a long run isn't escalated as a malfunction — but still capped, since
#                exempting it would reopen the very hole #40 closed (a job alive but
#                never finishing would re-dispatch forever with no backstop).
#   hard class   every `**Worker interrupted:` (cut off — a full WORKER_BUDGET already
#                burned) and every OTHER incomplete reason (`uncommitted`, `unpushed`,
#                `nopr`, `draft`, `conflicting` — the session exited having
#                malfunctioned or left an unmergeable PR, not having handed off).
#                Tight cap (WORKER_LIMIT). Membership is by DEFAULT, not by an
#                enumeration: anything that isn't the wait lead lands here, so a new
#                reason token is hard-class unless deliberately exempted (issue #51).
#
# Classification reads the reason token out of the comment lead and nothing else — no
# tmux probe, no filesystem timestamps. This script runs at cycle start and stays a pure
# comment-history reader, so it must not depend on live session state.
NO_FINISH_LEADS = ("**Worker interrupted:", "**Worker incomplete:")
WAIT_LEAD_RE = re.compile(r"^\*\*Worker incomplete:\s*(?:incomplete-)?waiting\b")

def trailing_no_finish_counts(repo, num):
    """How many `**Worker interrupted:` / `**Worker incomplete:` comments (posted by
    finalize_dispatch, see dispatch-common.sh) sit at the END of the issue's comment
    history with nothing else after them, split into (hard, wait) per the classes above.
    Any intervening comment (a milestone, a checker verdict, a human reply) resets BOTH
    — the same 'per generation' idea CHECKER_LIMIT uses for verdict comments, so a
    genuinely-progressing issue never gets penalized for an interruption two rounds
    ago."""
    comments = issue_comments(repo, num)
    if comments is None:
        return None
    hard = wait = 0
    for c in reversed(comments):
        body = c.get("body") or ""
        if not body.startswith(NO_FINISH_LEADS):
            break
        if WAIT_LEAD_RE.match(body):
            wait += 1
        else:
            hard += 1
    return hard, wait

def escalate_needs_input(repo, num, n, limit, knob, what, also=""):
    """Post the ONE escalation comment for this prune. `also` is the *other* class's
    trailing count, reported as context — the operator reads this comment instead of
    the ledger, so a run that tripped one class while accumulating rounds of the other
    must say so here or that half of the record silently disappears (#40 PR #46
    round-5 review, folded into issue #51). It is appended to the same comment, never
    posted as a second one, and it never displaces the trigger's own naming."""
    try:
        subprocess.run(["gh", "issue", "edit", str(num), "-R", repo,
                         "--add-label", "needs-input"], capture_output=True, timeout=15)
        subprocess.run(["gh", "issue", "comment", str(num), "-R", repo, "--body",
            f"🔁 Worker limit reached: {n} {what} in a row, never reaching `ready` "
            f"(limit {limit}, `{knob}`). "
            + (f"{also} " if also else "")
            + f"Escalating to "
            f"@{os.environ.get('GITHUB_HANDLE','')} — the "
            f"issue may be too large for one worker budget, or something is "
            f"silently blocking progress."], capture_output=True, timeout=15)
    except Exception:
        pass

# board-digest.sh now derives dispatch structurally from PR state (a draft PR
# with no live worker is the worker's court regardless of labels), so recovery
# from an interruption no longer depends on relabeling anything here. But
# nothing else caps a *chronically* interrupted issue — it would get
# redispatched every cycle forever. WORKER_LIMIT (mirrors CHECKER_LIMIT) closes
# that: count consecutive trailing "interrupted" comments (posted by
# finalize_dispatch on every hard stop) and once the limit is hit, hand it to
# the operator instead of burning another worker budget on it. WORKER_WAIT_LIMIT is
# the same backstop at a looser setting for the cheap wait class (see above).
WORKER_LIMIT = int(os.environ.get("WORKER_LIMIT", "4"))
WORKER_WAIT_LIMIT = int(os.environ.get("WORKER_WAIT_LIMIT", "10"))

def handle_no_clean_finish(repo, num):
    labs = issue_labels(repo, num)
    if labs is None or labs & {"needs-input", "checked-pass"}:
        return None  # already escalated or passed elsewhere — leave it alone
    counts = trailing_no_finish_counts(repo, num)
    if counts is None:
        return None
    hard, wait = counts
    # Each class is tallied independently and escalates on ITS OWN limit; a mixed
    # trailing run therefore doesn't escalate until one class gets there alone. The
    # class that DIDN'T trip still gets one line of context in the same comment (see
    # escalate_needs_input) so the operator sees the whole trailing run, not half of it.
    if hard >= WORKER_LIMIT:
        also = (f"Also in the same trailing run: {wait} exit-to-wait attempt(s) "
                f"(`incomplete-waiting`, counted separately against `WORKER_WAIT_LIMIT` "
                f"at {wait}/{WORKER_WAIT_LIMIT}) — context, not the trigger."
                if wait else "")
        escalate_needs_input(repo, num, hard, WORKER_LIMIT, "WORKER_LIMIT",
                             "interrupted/unfinalized attempts", also)
        return f"WORKER_LIMIT reached ({hard}/{WORKER_LIMIT}) — escalated to needs-input"
    if wait >= WORKER_WAIT_LIMIT:
        also = (f"Also in the same trailing run: {hard} interrupted/unfinalized "
                f"attempt(s) (counted separately against `WORKER_LIMIT` at "
                f"{hard}/{WORKER_LIMIT}) — context, not the trigger."
                if hard else "")
        escalate_needs_input(repo, num, wait, WORKER_WAIT_LIMIT, "WORKER_WAIT_LIMIT",
                             "exit-to-wait attempts (`incomplete-waiting`)", also)
        return (f"WORKER_WAIT_LIMIT reached ({wait}/{WORKER_WAIT_LIMIT})"
                " — escalated to needs-input")
    # Cosmetic only (digest doesn't need it) — keeps the plain GitHub label view
    # legible for a human scanning issues outside the orchestrator's own digest.
    if "resume" not in labs and has_open_pr(repo, num) is True:
        relabel_resume(repo, num)
    return None

def is_terminal(status):
    """Has this line been finalized by anything — its own finalize_dispatch, or the
    reconciler above? The whole ledger status vocabulary except `dispatched` (and any
    unrecognized token) counts."""
    if not status:
        return False
    return status in ("done", "unknown") or status.startswith(("incomplete", "interrupted"))

keep, pruned = [], []
for ln in lines:
    m = re.search(r"#(\d+)\s*\|\s*([^|]+?)\s*\|", ln)
    if not m:                      # blank/header line — preserve verbatim
        keep.append(ln)
        continue
    num, repo = int(m.group(1)), m.group(2).strip()
    pid = (re.search(r"pid\s+(\S+)", ln) or [None, None])[1]
    status = (re.search(r"status\s+(\S+)", ln) or [None, None])[1]
    fields = [f.strip() for f in ln.split("|")]
    log = fields[3] if len(fields) > 3 else ""
    is_checker = "check pr#" in ln.lower()   # checker entry: num is a PR, not an issue
    reasons = []
    if is_checker:
        if pr_done(repo, num):
            reasons.append("PR closed/merged")
    elif issue_closed(repo, num):
        reasons.append("issue closed")
    if pid_dead(pid):
        reasons.append(f"pid {pid} dead")
    # NEVER drop an unreconciled dispatch in silence (issue #63). Phase 1 reconciles every
    # dead-pid non-terminal entry, so a line that is STILL non-terminal here is one
    # reconciliation could not finalize — a `-`/unparseable pid (so liveness is unknowable,
    # and the prune reason is the closed issue/PR, not the pid), or a worker whose worktree
    # is gone. That used to be dropped with no warning, no comment and no cap advanced,
    # which is how a completed review evaporated. Name the entry, its log, and whether a
    # verdict file is sitting there unread, so the operator can recover it by hand.
    if reasons and not is_terminal(status):
        vf = (log[:-4] + "-verdict.json") if log.endswith(".log") else ""
        found = "present" if vf and os.path.exists(vf) else "absent"
        reasons.append(
            f"⚠ NOT reconciled — still `status {status}`; log {log or '<none>'}; "
            f"verdict file {found}"
            + (f" ({vf})" if found == "present" else "")
            + " — nothing was posted and no cap advanced for this dispatch")
    # Surface a dispatch that did not finish cleanly as it's pruned — interrupted
    # (rate limit / budget / crash) or incomplete (exited without finalizing, #40).
    # The launcher records both in `status`; without this the cutoff is silent.
    if reasons and status and status.startswith(("interrupted", "incomplete")):
        reasons.append(f"⚠ was {status} — check worktree for unpushed work")
        if not is_checker:
            note = handle_no_clean_finish(repo, num)
            if note:
                reasons.append(note)
    (pruned if reasons else keep).append((ln, reasons) if reasons else ln)

with open(ledger, "w") as f:
    f.write("\n".join(keep) + ("\n" if any(l.strip() for l in keep) else ""))

for ln, why in pruned:
    sys.stderr.write(f"pruned: {ln.strip()}  ({', '.join(why)})\n")
live = sum(1 for l in keep if re.search(r"#\d+\s*\|", l))
print(f"ledger-prune: kept {live} live, pruned {len(pruned)}")
PY
