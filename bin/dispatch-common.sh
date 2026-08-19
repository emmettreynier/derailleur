#!/usr/bin/env bash
# dispatch-common.sh — shared helpers for launch-worker.sh / launch-checker.sh (mostly
# post-run; `rotate_verdict_file` is the one pre-dispatch member, parked here so the
# offline tests can source it without booting `claude`).
# SOURCED, not executed. Its job: make a dispatch that did not finish record itself
# honestly, instead of looking like a clean finish. Two distinct failure shapes:
#
#   1. INTERRUPTED (rate limit, budget cap, crash) -> `interrupted-*`.
#      `claude --output-format json` can exit with subtype "success" yet is_error:true +
#      api_error_status:429 ("session limit") — a cutoff that leaves work committed
#      locally but UNPUSHED. Keying completion off `subtype` alone (as a naive read
#      does) mistakes that for done. classify_result reads the real fields.
#   2. INCOMPLETE (exit-to-wait) -> `incomplete-<reason>` (issue #40).
#      A genuinely clean exit-0 that finalized nothing: typically an agent that handed a
#      long run to `dr tmux-run` and — correctly, per its brief — exited to let the next
#      dispatch reattach, leaving the PR draft or no verdict written. assert_finalized
#      catches this; classify_result cannot see it and deliberately doesn't try.
#
# Ledger status vocabulary: dispatched | done | incomplete-* | interrupted-* | unknown.
# Consumers prefix-match `incomplete*` exactly as they do `interrupted*`.
#
# It also owns the CHECKER ROUND VOCABULARY (`CHECKER_ROUND_LEADS` +
# `checker_rounds_this_generation` below) — the leads this file posts and the counter
# orchestrator-cycle.sh reads them with, kept in one place so they cannot drift.

# classify_result <log> -> echoes: done | interrupted-ratelimit | interrupted-budget
#   | interrupted-error | unknown.  Parses the final JSON result line in the log.
#
# DELIBERATELY a pure log-JSON parser (issue #40): "the session exited without an
# error" and "the session actually finalized something" are different questions.
# assert_finalized below answers the second one and is consulted separately, so each
# half stays independently testable.
classify_result() {
  python3 - "$1" <<'PY'
import json, sys
# Find the claude result JSON by scanning lines in REVERSE for the last one that
# parses as a result object — NOT just "the last non-empty line". The checker
# appends its mutation-check line AFTER the JSON (report_mutation runs before
# finalize_dispatch), so a naive last-line read parses that prose and yields
# "unknown". Scanning for type=="result" is robust to any trailing output.
d = None
try:
    for line in reversed([l for l in open(sys.argv[1]) if l.strip()]):
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            d = obj
            break
except Exception:
    pass
if d is None:
    print("unknown"); sys.exit()
sub = (d.get("subtype") or "")
result = (d.get("result") or "").lower()
if d.get("api_error_status") == 429 or "session limit" in result or "rate limit" in result:
    print("interrupted-ratelimit")
elif "budget" in sub:
    print("interrupted-budget")
elif d.get("is_error"):
    print("interrupted-error")
else:
    print("done")
PY
}

# record_usage_reset <log> — if <log> ends in a Claude session-limit hit, parse the
# "resets 7:40pm" prose out of the result and park the reset epoch in state/usage-reset
# so run-cycle.sh can DEFER the next scheduled fire instead of booting into a 429.
# These dispatches run on the operator's subscription (no API key), so they share the 5-hour
# rolling session limit — the only reset signal Claude gives is this prose, and only
# AFTER you've hit the wall (no way to query it ahead of time). Unparseable -> assume a
# conservative full 5h window. Keeps the LATER of any existing marker and this one.
record_usage_reset() {
  local orch; orch="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$orch/state"
  python3 - "$1" "$orch/state/usage-reset" <<'PY' 2>/dev/null || true
import re, sys, time
log, dest = sys.argv[1], sys.argv[2]
try:
    tail = open(log, errors="replace").read()[-4000:]
except Exception:
    sys.exit()
if "session limit" not in tail.lower():
    sys.exit()
m = re.search(r"resets\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)", tail, re.I)
if m:
    hr = int(m.group(1)) % 12
    if m.group(3).lower() == "pm": hr += 12
    n = time.localtime()
    epoch = time.mktime(time.struct_time(
        (n.tm_year, n.tm_mon, n.tm_mday, hr, int(m.group(2) or 0), 0,
         n.tm_wday, n.tm_yday, -1)))
    if epoch <= time.time():          # clock time already past today -> tomorrow
        epoch += 86400
else:
    epoch = time.time() + 5*3600      # unparseable -> conservative 5-hour window
try:
    prev = float(open(dest).read().split()[0])
except Exception:
    prev = 0
epoch = max(epoch, prev)
open(dest, "w").write(
    f"{int(epoch)} {time.strftime('%Y-%m-%d %H:%M', time.localtime(epoch))}\n")
PY
}

# _ledger_set_status <ledger> <pid> <status> — flip `status …` on the ledger line
# whose `pid <pid>` matches. Short mkdir-lock so two finishers don't clobber the file.
_ledger_set_status() {
  local ledger="$1" pid="$2" st="$3" lock="$1.lock" i=0
  [ "$pid" = "-" ] && return 0
  while ! mkdir "$lock" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 100 ] && break; sleep 0.1; done
  LEDGER="$ledger" PID="$pid" STATUS="$st" python3 - <<'PY'
import os, re
ledger, pid, status = os.environ["LEDGER"], os.environ["PID"], os.environ["STATUS"]
try:
    lines = open(ledger).read().splitlines()
except FileNotFoundError:
    lines = []
out = [re.sub(r"status \S+.*$", f"status {status}", ln)
       if re.search(rf"\bpid {re.escape(pid)}\b", ln) else ln
       for ln in lines]
open(ledger, "w").write("\n".join(out) + ("\n" if out else ""))
PY
  rmdir "$lock" 2>/dev/null || true
}

# tmux_job_state <name> -> echoes exactly: alive | dead | absent
#   alive  = the session exists AND its pane is still running
#   dead   = the session exists but its pane finished (tmux-run.sh's remain-on-exit)
#   absent = no such session (also: tmux isn't installed on this host)
#
# LOAD-BEARING: liveness is `#{pane_dead}`-based, mirroring tmux-run.sh's own
# classification block — NOT `has-session` alone. tmux-run.sh arms `remain-on-exit on`
# in the same invocation that creates the session, so a FINISHED job's session lingers
# for the next worker to inspect (even one that finished in milliseconds); keying off
# has-session would report every completed-but-not-torn-down run as still running,
# forever.
tmux_job_state() {
  local name="${1:-}" dead
  if [ -z "$name" ] || ! command -v tmux >/dev/null 2>&1; then
    echo "absent"; return 0
  fi
  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo "absent"; return 0
  fi
  dead="$(tmux list-panes -t "$name" -F '#{pane_dead}' 2>/dev/null | head -1)"
  if [ "$dead" = 1 ]; then echo "dead"; else echo "alive"; fi
  return 0
}

# _log_dispatch_num <log> -> the issue/PR number encoded in the log basename
# (logs/<slug>-issue-N.log, logs/<slug>-pr-N.log). Empty if it doesn't match.
# Derived rather than passed so finalize_dispatch's signature stays unchanged.
_log_dispatch_num() {
  local base; base="$(basename "${1:-}")"
  printf '%s' "${base%.log}" | sed -nE 's/^.+-(issue|pr)-([0-9]+)$/\2/p'
  return 0
}

# _worktree_repo <worktree> -> owner/repo from the worktree's origin remote (empty
# if it can't be read).
_worktree_repo() {
  git -C "${1:-}" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##; s#\.git$##'
  return 0
}

# _pr_mergeable <repo> <pr#> -> echoes exactly one of: CONFLICTING | MERGEABLE | INCONCLUSIVE
#
# WHY THE RETRY (issue #51): GitHub computes `mergeable` **asynchronously**. For a few
# seconds after a push — which is exactly when a worker exits — `gh pr view --json
# mergeable` returns `UNKNOWN` while GitHub recomputes the test merge. `UNKNOWN` is
# therefore the EXPECTED first answer, not an error: a no-retry check would almost
# never see a real verdict and the rung would be dead code.
#
# WHY IT IS PERMISSIVE: only an explicit `CONFLICTING` is a fact. `MERGEABLE`, a stuck
# `UNKNOWN`, an unrecognized value, a non-zero `gh` exit and unparseable output all
# collapse to INCONCLUSIVE, which the caller treats as "not conflicting" — the same
# no-false-`incomplete`-from-a-flaky-network rule the nopr/draft checks follow. Do NOT
# "simplify" this into a strict check.
#
# BOUNDED: one poll plus up to MERGEABLE_REPOLLS re-polls MERGEABLE_POLL_SLEEP apart,
# under a hard MERGEABLE_POLL_CEILING wall-clock ceiling (checked BEFORE each sleep, so
# the ceiling bounds the sleeps too) — a worker's exit path must never hang on GitHub.
# The three knobs are env-overridable so the offline tests exercise this same code with
# the sleeps zeroed; the defaults are the contract (2 re-polls, ~3s apart, ≤10s added).
_pr_mergeable() {
  local repo="${1:-}" pr="${2:-}"
  local repolls="${MERGEABLE_REPOLLS:-2}"
  local nap="${MERGEABLE_POLL_SLEEP:-3}"
  local ceiling="${MERGEABLE_POLL_CEILING:-10}"
  local start="$SECONDS" polls=0 rc out m
  while : ; do
    rc=0
    out="$(gh pr view "$pr" -R "$repo" --json mergeable 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "INCONCLUSIVE"; return 0
    fi
    m="$(printf '%s' "$out" | jq -r '.mergeable // empty' 2>/dev/null || true)"
    case "$m" in
      CONFLICTING) echo "CONFLICTING"; return 0 ;;
      MERGEABLE)   echo "MERGEABLE";   return 0 ;;
      UNKNOWN)     : ;;                              # still computing — re-poll
      *)           echo "INCONCLUSIVE"; return 0 ;;  # empty/unparseable/unrecognized
    esac
    polls=$((polls + 1))
    if [ "$polls" -gt "$repolls" ]; then
      break
    fi
    if [ $((SECONDS - start + nap)) -ge "$ceiling" ]; then
      break
    fi
    sleep "$nap"
  done
  echo "INCONCLUSIVE"
  return 0
}

# assert_finalized <kind> <log> <worktree> [repo] -> prints "" when the dispatch
# actually finalized something, else ONE reason token naming the first failed check.
#
# [repo] is an optional `owner/repo` override for a caller whose worktree can no longer
# answer for it — ledger-prune.sh's reconciler runs long after the dispatch, possibly
# after worktree-prune removed the tree, and carries the repo on the ledger line instead
# (issue #63). Unset/empty keeps the original behaviour: derive it from the worktree.
#
# WHY (issue #40): a clean exit-0 is not the same as a finished job. A worker that
# hands a long run to `dr tmux-run` is told to exit cleanly and let the next dispatch
# reattach — a correct, intended exit-to-wait that nevertheless leaves the PR draft
# and no deliverable committed. classify_result sees exit-0 and says `done`, and every
# downstream consumer reads `done` as "finalized". This closes that hole: the ledger
# records `incomplete-<reason>` instead, which is countable (ledger-prune's
# WORKER_LIMIT / orchestrator-cycle's NROUNDS) so a chronically unfinishable
# issue/PR escalates to needs-input rather than re-dispatching forever.
#
# Consulted ONLY when classify_result returned `done` — an `interrupted-*`
# classification is already more informative and keeps its status.
#
# Order matters (first failure wins):
#   worker : waiting -> uncommitted -> unpushed -> nopr -> draft -> conflicting
#   checker: waiting -> noverdict
#
# `conflicting` is deliberately LAST: it is the only rung that costs an extra network
# round-trip (and possibly a bounded retry), so every cheap local signal gets to win
# first — a draft PR reports `draft` and never triggers a mergeability lookup at all.
# The checker ladder does NOT gain it: a checker does not own PR mergeability.
#
# NO FALSE INCOMPLETE FROM A FLAKY NETWORK: a failed/unparseable `gh` lookup SKIPS the
# nopr/draft/conflicting checks with a stderr note rather than asserting a reason. Only
# local, deterministic signals (git, the filesystem, tmux) — plus an *explicit*
# `mergeable == "CONFLICTING"` from GitHub — may assert one.
assert_finalized() {
  local kind="$1" log="$2" worktree="$3" repo_in="${4:-}"
  local num repo tmux_name
  num="$(_log_dispatch_num "$log")"
  repo="$repo_in"
  [ -n "$repo" ] || repo="$(_worktree_repo "$worktree")"

  # (1) waiting — a detached run for this task is still going (both roles).
  # The session name is a pure function of the task (tmux-run.sh:87); issue and PR
  # numbers share one namespace per repo, so it's unambiguous across roles.
  if [ -n "$repo" ] && [ -n "$num" ]; then
    tmux_name="derail-${repo//\//-}-$num"
    if [ "$(tmux_job_state "$tmux_name")" = "alive" ]; then
      echo "waiting"; return 0
    fi
  fi

  if [ "$kind" = "checker" ]; then
    # (2c) noverdict — the checker's whole deliverable is the verdict JSON.
    local vf="${log%.log}-verdict.json" v
    if [ ! -f "$vf" ]; then
      echo "noverdict"; return 0
    fi
    v="$(jq -r '.verdict // empty' "$vf" 2>/dev/null || true)"   # unparseable -> empty
    if [ -z "$v" ]; then
      echo "noverdict"; return 0
    fi
    return 0
  fi

  # (2w) uncommitted — tracked changes still sitting in the worktree. `-uno` so a
  # stray untracked scratch file (or an unlinked data dir) never trips this.
  if [ -n "$(git -C "$worktree" status --porcelain -uno 2>/dev/null)" ]; then
    echo "uncommitted"; return 0
  fi

  # (3w) unpushed — commits ahead of the upstream, or no upstream at all (a branch
  # that was never pushed has nothing on GitHub for a reviewer or checker to see).
  local ahead
  ahead="$(git -C "$worktree" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '')"
  case "$ahead" in
    ''|*[!0-9]*) echo "unpushed"; return 0 ;;   # no upstream / unreadable
    0)           : ;;
    *)           echo "unpushed"; return 0 ;;
  esac

  # (4w/5w) nopr / draft — the PR is the worker's finalization signal (PR-ready is
  # also the sole checker trigger, so a draft PR is by definition not finished).
  if [ -z "$repo" ] || [ -z "$num" ]; then
    echo "  note: could not derive repo/number (log=$log) — skipping nopr/draft checks" >&2
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "  note: gh not on PATH — skipping nopr/draft checks" >&2
    return 0
  fi
  local pr_json pr_rc=0 npr
  pr_json="$(gh pr list -R "$repo" --head "issue-$num" --state open --json isDraft,number 2>/dev/null)" \
    || pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    echo "  note: gh PR lookup failed for $repo (head issue-$num) — skipping nopr/draft checks" >&2
    return 0
  fi
  npr="$(printf '%s' "$pr_json" | jq -r 'if type=="array" then length else "?" end' 2>/dev/null \
         || printf '?')"
  case "$npr" in
    ''|*[!0-9]*)
      echo "  note: gh PR lookup returned unparseable JSON for $repo — skipping nopr/draft checks" >&2
      return 0 ;;
  esac
  if [ "$npr" -eq 0 ]; then
    echo "nopr"; return 0
  fi
  if [ "$(printf '%s' "$pr_json" | jq -r '.[0].isDraft' 2>/dev/null || true)" = "true" ]; then
    echo "draft"; return 0
  fi

  # (6w) conflicting — the PR is READY but GitHub cannot merge it (issue #51). Without
  # this rung a ready-but-unmergeable PR passes the whole battery and the worker's own
  # exit reports `done` on a deliverable that cannot land; the digest then reads it as a
  # ready PR awaiting a checker, and a whole CHECKER_BUDGET round is spent discovering
  # the conflict. Reached only here, after `draft` has passed — see _pr_mergeable for
  # why the lookup retries and why it asserts ONLY on an explicit CONFLICTING.
  local prnum mergeable
  prnum="$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null || true)"
  case "$prnum" in
    ''|*[!0-9]*)
      echo "  note: gh PR lookup carried no usable PR number for $repo — skipping conflicting check" >&2
      return 0 ;;
  esac
  mergeable="$(_pr_mergeable "$repo" "$prnum")"
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "conflicting"; return 0
  fi
  if [ "$mergeable" = "INCONCLUSIVE" ]; then
    echo "  note: gh mergeability lookup inconclusive for $repo#$prnum — treating as not conflicting" >&2
  fi
  return 0
}

# CHECKER_ROUND_LEADS — the ONE enumeration of every comment lead that constitutes a
# checker round on a PR (issue #52). Two of the three are posted by finalize_dispatch
# below (`incomplete` / `interrupted`); the third is posted by the checker itself
# (`**Checker verdict:`, see briefs/checker-brief.md). orchestrator-cycle.sh counts
# rounds through checker_rounds_this_generation, which reads THIS list — so a lead can
# never be added to the poster without the counter seeing it, the failure that left an
# interrupted checker uncountable and re-checked every cycle forever.
#
# Newline-separated string, not an array: it has to cross into python, and a bash 3.2
# array under `set -u` is the wrong tool for a value that is never empty (CLAUDE.md).
CHECKER_ROUND_LEADS='**Checker verdict:
**Checker incomplete:
**Checker interrupted:'

# checker_rounds_this_generation — reads `gh pr view <pr> --json comments` JSON on
# STDIN, echoes how many checker rounds sit in the CURRENT review generation.
#
# Rounds are counted PER GENERATION, not over the PR's lifetime: a to-operator verdict
# (pass / pass_with_findings / blocked) hands the ball to the operator and ends a
# generation, so only rounds AFTER the most recent one count. `changes_requested` /
# `fail` keeps the ball worker-side and does NOT end a generation — and neither an
# `incomplete` nor an `interrupted` round can, since neither decided anything.
#
# Fails soft: unreadable/unparseable input echoes 0 (never escalate on a flaky `gh`).
checker_rounds_this_generation() {
  CHECKER_ROUND_LEADS="$CHECKER_ROUND_LEADS" python3 -c '
import sys, json, os, re
leads = tuple(l for l in os.environ["CHECKER_ROUND_LEADS"].split("\n") if l)
try:
    comments = json.load(sys.stdin).get("comments", [])
except Exception:
    print(0); sys.exit()
rounds = [b for b in ((c.get("body") or "") for c in comments) if b.startswith(leads)]
to_operator = {"pass", "pass_with_findings", "blocked"}   # verdicts that end a generation
last_handoff = -1
for i, b in enumerate(rounds):
    m = re.match(r"\*\*Checker verdict:\s*`?\s*([a-z_]+)", b, re.I)
    if (m.group(1).lower() if m else "") in to_operator:
        last_handoff = i
print(len(rounds) - (last_handoff + 1))
' 2>/dev/null || echo 0
  return 0
}

# finalize_dispatch <log> <ledger> <pid> <worktree> <kind> — run AFTER the claude
# process exits: classify the outcome, record it in the ledger, and on anything short
# of a clean finish warn loudly + push commits the re-dispatch would otherwise strand.
# `pid` is "-" for foreground runs (the ledger line isn't pid-keyed there; the warning
# still fires).
finalize_dispatch() {
  local log="$1" ledger="$2" pid="$3" worktree="$4" kind="$5"
  local st; st="$(classify_result "$log")"
  # A clean exit still has to prove it finalized something (issue #40) — an
  # exit-to-wait on a detached tmux run is exit-0 but not done.
  if [ "$st" = "done" ]; then
    local reason; reason="$(assert_finalized "$kind" "$log" "$worktree")"
    if [ -n "$reason" ]; then
      st="incomplete-$reason"
    fi
  fi
  _ledger_set_status "$ledger" "$pid" "$st"
  if [ "$st" = "done" ]; then
    echo "$kind finished cleanly."
    return 0
  fi
  echo "⚠ $kind did NOT finish cleanly — status: $st" >&2
  # A session-limit cutoff means the whole subscription window is spent — park the
  # reset so the scheduler defers the next fire instead of dispatching into a 429.
  [ "$st" = "interrupted-ratelimit" ] && record_usage_reset "$log"

  report_no_clean_finish "$kind" "$st" "$log" "$worktree"
}

# report_no_clean_finish <kind> <status> <log> <worktree> [repo] [num] — the shared tail
# of a dispatch that did not finish cleanly: push commits the next dispatch would
# otherwise strand, then leave the ONE countable comment the caps read.
#
# EXTRACTED from finalize_dispatch (issue #63) so it can also run from OUTSIDE the
# dispatched session. When a session is killed outright — SIGKILL, host sleep, OOM — the
# trailing `bash -c` chain run_in_new_session appends never reaches finalize_dispatch at
# all, so none of this ever ran: no push, and no `**Worker/Checker interrupted:` comment,
# which is what left the round uncountable and the same PR re-checked at a full
# CHECKER_BUDGET every cycle. ledger-prune.sh's reconciler calls this directly instead.
# It must stay the SINGLE place these bodies are written: the caps match on the LEAD, so a
# second copy that drifted would silently stop counting.
#
# [repo] / [num] are overrides for a caller with no usable worktree (a reconciler running
# after worktree-prune removed it): `repo` normally comes from the worktree's origin
# remote and a worker's issue number from its branch name, neither of which survives that.
# `num` is the issue number for a worker, the PR number for a checker — the same numbers
# the unassisted derivations produce, so passing them changes nothing but the source.
report_no_clean_finish() {
  local kind="$1" st="$2" log="$3" worktree="$4" repo_in="${5:-}" num_in="${6:-}"
  # A hard stop (budget cap, rate limit, crash) never reaches the worker's own
  # `git push`, and never fires the Stop hook (there's no clean-exit event to
  # hook) — so a local commit would otherwise sit invisible until SOME future
  # redispatch happens to push it. Push it now, best-effort, instead of waiting.
  local ahead push_note=""
  ahead="$(git -C "$worktree" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
  if [ "$ahead" != "?" ] && [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    if git -C "$worktree" push >>"$log" 2>&1; then
      push_note=" — pushed $ahead commit(s), branch is up to date on GitHub"
      echo "  pushed $ahead unpushed commit(s) from $worktree." >&2
    else
      push_note=" — ⚠ $ahead commit(s) FAILED to push; check $worktree"
      echo "  ⚠ push failed for $worktree — $ahead commit(s) remain local-only." >&2
    fi
  fi

  # Leave a durable, countable trail on the issue/PR — the same comment-is-signal
  # convention the checker uses for its verdicts (`**Checker verdict: …`). The caps
  # count these: ledger-prune.sh's WORKER_LIMIT counts trailing `**Worker interrupted:`
  # AND `**Worker incomplete:` comments; orchestrator-cycle.sh's NROUNDS counts every
  # lead in CHECKER_ROUND_LEADS above. Without that, an exit-to-wait produced NEITHER
  # signal and a wedged job re-dispatched every cycle forever with no path to
  # needs-input (issue #40).
  #
  # BOTH ROLES POST BOTH LEADS (issue #52). The checker used to post `incomplete` only,
  # so an interrupted checker — rate-limiting being the likeliest cause, i.e. the common
  # case — left nothing countable and the same PR was re-checked every cycle at a full
  # CHECKER_BUDGET with CHECKER_LIMIT frozen at zero. Same hole #40 closed worker-side.
  local lead="interrupted"
  case "$st" in incomplete-*) lead="incomplete" ;; esac
  local repo="$repo_in"
  [ -n "$repo" ] || repo="$(_worktree_repo "$worktree")"

  if [ "$kind" = "worker" ]; then
    local issue="$num_in"
    if [ -z "$issue" ]; then
      issue="$(git -C "$worktree" branch --show-current 2>/dev/null | sed -nE 's/^issue-([0-9]+)$/\1/p')"
    fi
    if [ -n "$repo" ] && [ -n "$issue" ]; then
      local body
      if [ "$st" = "incomplete-conflicting" ]; then
        # Named explicitly, not left to the generic incomplete text: a bare status
        # invites the next worker to re-verify and re-mark the PR ready instead of
        # resolving anything (observed on #40 round 3, issue #51).
        body="**Worker incomplete: $st**${push_note}. The PR is marked **ready but GitHub reports it as \`CONFLICTING\`** — it cannot be merged, so the deliverable is unusable as it stands. This is NOT something to re-verify: the conflict has to be resolved. On re-dispatch, in the \`issue-$issue\` worktree, run \`git fetch origin && git merge origin/main\`, resolve the conflicted files, commit, and push — then leave the PR ready. Counts against \`WORKER_LIMIT\` (a conflict is a real blocker, not an exit-to-wait handoff), so repeated rounds escalate to \`needs-input\`."
      elif [ "$lead" = "incomplete" ]; then
        body="**Worker incomplete: $st**${push_note}. The session exited cleanly but did NOT finalize (first unmet check: \`${st#incomplete-}\`) — most often an exit-to-wait on a detached \`dr tmux-run\` job. Re-dispatch to reattach-and-babysit per the worker brief; repeated attempts on this issue with no clean finish will escalate to \`needs-input\`."
      else
        body="**Worker interrupted: $st**${push_note}. Not a failure by itself — the orchestrator recovers this automatically next cycle; repeated attempts on this issue with no clean finish will eventually escalate to \`needs-input\`."
      fi
      gh issue comment "$issue" -R "$repo" --body "$body" \
        >>"$log" 2>&1 || echo "  ⚠ could not post $lead comment on $repo#$issue" >&2
    fi
  elif [ "$kind" = "checker" ]; then
    # PR number comes from the LOG basename, not the branch: a checker runs in the
    # worker's `issue-N` worktree, so the branch names the issue, not the PR.
    local pr="$num_in"
    [ -n "$pr" ] || pr="$(_log_dispatch_num "$log")"
    if [ -n "$repo" ] && [ -n "$pr" ]; then
      local cbody
      if [ "$lead" = "incomplete" ]; then
        cbody="**Checker incomplete: $st**${push_note}. The session exited cleanly but wrote no usable verdict (first unmet check: \`${st#incomplete-}\`). No verdict was recorded, so this round decided nothing; repeated rounds without a to-operator verdict count toward \`CHECKER_LIMIT\` and escalate to \`needs-input\`."
      else
        cbody="**Checker interrupted: $st**${push_note}. The session was cut off before it could write a verdict (rate limit, budget cap, or crash). Not a failure by itself — the orchestrator re-checks this PR next cycle; but no verdict was recorded, so this round decided nothing, and repeated rounds without a to-operator verdict count toward \`CHECKER_LIMIT\` and escalate to \`needs-input\`."
      fi
      gh pr comment "$pr" -R "$repo" --body "$cbody" \
        >>"$log" 2>&1 || echo "  ⚠ could not post $lead comment on $repo#$pr" >&2
    fi
  fi
}

# ── reconciling a dispatch that DIED before finalize_dispatch (issue #63) ─────────────
# finalize_dispatch runs INSIDE the dispatched session, appended to run_in_new_session's
# trailing `bash -c` chain. A session killed outright never reaches it, so its ledger line
# stays at `status dispatched` against a pid that is already gone, and — for a checker — a
# review that COMPLETED evaporates: the verdict JSON is on disk, but the label the brief
# tells the checker to apply as its last act was never applied, so the PR never reaches the
# operator's merge gate and nothing countable is posted. The three helpers below are what
# lets ledger-prune.sh redo that finalization from outside the dead process.

# reconciled_status <kind> <log> <worktree> [repo] -> the terminal status a dispatch that
# died before finalize_dispatch should carry: classify_result on the log, then the
# assert_finalized battery for its kind.
#
# Differs from finalize_dispatch in exactly one place, deliberately: `unknown` gets the
# battery too. finalize_dispatch consults assert_finalized only after a `done`
# classification because it judges a process it just watched exit normally — there IS a
# result JSON to read. A reconciler judges a process that was KILLED, which is precisely
# why nothing finalized it: no result JSON was ever written (the observed case had a 0-byte
# log), so `unknown` is the EXPECTED classification here, not an anomaly. Refusing the
# battery there would leave every reconciled entry at `unknown`, reporting nothing about
# whether the deliverable actually landed — and the verdict JSON sitting in logs/ is
# exactly the evidence that decides it.
#
# An explicit `interrupted-*` keeps its status, as in finalize_dispatch: it names a real
# cause (rate limit, budget cap) the battery cannot improve on.
reconciled_status() {
  local kind="$1" log="$2" worktree="$3" repo="${4:-}"
  local st reason
  st="$(classify_result "$log")"
  case "$st" in
    done|unknown)
      reason="$(assert_finalized "$kind" "$log" "$worktree" "$repo")"
      if [ -n "$reason" ]; then st="incomplete-$reason"; else st="done"; fi ;;
  esac
  printf '%s\n' "$st"
  return 0
}

# verdict_of <verdict-file> -> the `verdict` field, or empty when the file is missing,
# unparseable, or carries no verdict. Same "unparseable -> empty" rule as
# assert_finalized's noverdict rung, so the two can never disagree about whether a
# checker produced a usable deliverable.
verdict_of() {
  local vf="${1:-}"
  if [ ! -f "$vf" ]; then
    printf ''
    return 0
  fi
  jq -r '.verdict // empty' "$vf" 2>/dev/null || printf ''
  return 0
}

# verdict_label <verdict> -> the issue label that verdict routes to (empty if the verdict
# token is unrecognized).
#
# THE ONE COPY of the checker's verdict -> label mapping outside the brief.
# briefs/checker-brief.md tells the CHECKER to apply these itself, as its last act, which
# is exactly why the mapping has to exist here as well: a death between writing the verdict
# JSON and running `gh issue edit` keeps the verdict and loses the label. Keep the two in
# sync — change the brief's routing block and change this.
#   pass / pass_with_findings -> checked-pass  (the operator's merge gate)
#   changes_requested / fail  -> resume        (worker's court; the PR also goes back to draft)
#   blocked                   -> needs-input   (the operator's court)
verdict_label() {
  case "${1:-}" in
    pass|pass_with_findings) echo "checked-pass" ;;
    changes_requested|fail)  echo "resume" ;;
    blocked)                 echo "needs-input" ;;
    *)                       echo "" ;;
  esac
  return 0
}

# publish_recovered_verdict <verdict-file> <repo> <pr> [issue] — perform the routing a
# checker that died before its last act never got to perform. Prints a one-line note
# naming what it published (empty when there was nothing to publish).
#
# Three acts, matching briefs/checker-brief.md's routing block:
#   1. the verdict's label on the closing ISSUE (routing labels live on the issue, not the PR);
#   2. the `**Checker verdict:` PR comment, so the round is countable by
#      CHECKER_ROUND_LEADS and the findings reach the operator at all — on disk they are
#      invisible;
#   3. for a worker-court verdict, flipping the PR back to draft. Not cosmetic: board-digest
#      strands a ready PR whose issue carries `resume` in NEITHER bucket — awaiting_check
#      excludes it on the label, and the resume bucket requires no open PR — so a label
#      without the flip hands the work to nobody.
#
# IDEMPOTENT by reading state before each act: the label only when absent, the comment only
# when the PR carries no `**Checker verdict:` comment at all (the checker may well have
# posted its own before dying), the flip only when the PR is currently ready. A second run
# publishes nothing and posts nothing.
#
# FAILS SOFT and says so: a `gh` lookup that errors or won't parse leaves everything alone
# rather than guessing. This runs unattended at cycle start, where a flaky network must
# never invent a merge gate or bounce a PR. It also never touches a PR that is no longer
# OPEN — a merged/closed PR's verdict is moot.
publish_recovered_verdict() {
  local vf="$1" repo="$2" pr="$3" issue="${4:-}"
  local v label pj rc=0 prstate labs body notes=""
  v="$(verdict_of "$vf")"
  if [ -z "$v" ]; then printf ''; return 0; fi
  label="$(verdict_label "$v")"
  if [ -z "$label" ]; then
    echo "  ⚠ $vf carries an unrecognized verdict '$v' — nothing routed (see briefs/checker-brief.md)" >&2
    printf ''; return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh not on PATH — verdict '$v' for $repo#$pr NOT routed (label \`$label\` still unapplied)" >&2
    printf ''; return 0
  fi
  pj="$(gh pr view "$pr" -R "$repo" --json isDraft,state,comments,closingIssuesReferences 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$pj" ]; then
    echo "  ⚠ gh PR lookup failed for $repo#$pr — verdict '$v' NOT routed (label \`$label\` still unapplied)" >&2
    printf ''; return 0
  fi
  prstate="$(printf '%s' "$pj" | jq -r '.state // empty' 2>/dev/null || true)"
  if [ "$prstate" != "OPEN" ]; then
    echo "  note: $repo#$pr is ${prstate:-unreadable}, not OPEN — verdict '$v' left unrouted (moot)" >&2
    printf ''; return 0
  fi
  [ -n "$issue" ] || issue="$(jq -r '.issue // empty' "$vf" 2>/dev/null || true)"
  [ -n "$issue" ] || issue="$(printf '%s' "$pj" | jq -r '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)"

  # (1) the label — only when the issue does not already carry it.
  if [ -n "$issue" ]; then
    labs="$(gh issue view "$issue" -R "$repo" --json labels 2>/dev/null \
            | jq -r '.labels[].name' 2>/dev/null || true)"
    # herestring, never `printf … | grep -q`: grep exits on match and hands the writer an
    # EPIPE, which under `set -o pipefail` inverts the test (tests/lib/assert.sh header).
    if grep -qxF -- "$label" <<<"$labs"; then
      notes="label \`$label\` already on #$issue"
    elif gh issue edit "$issue" -R "$repo" --add-label "$label" >/dev/null 2>&1; then
      notes="applied \`$label\` to #$issue"
    else
      echo "  ⚠ could not apply \`$label\` to $repo#$issue — apply it by hand from $vf" >&2
      notes="FAILED to apply \`$label\` to #$issue"
    fi
  else
    echo "  ⚠ could not determine the closing issue for $repo#$pr — label \`$label\` NOT applied" >&2
    notes="no closing issue found; \`$label\` unapplied"
  fi

  # (2) the countable verdict comment — only when the checker posted none itself.
  if printf '%s' "$pj" | jq -e '[.comments[].body | select(startswith("**Checker verdict:"))] | length > 0' >/dev/null 2>&1; then
    notes="$notes; the checker's own verdict comment is already on the PR"
  else
    body="**Checker verdict: $v**

_Recovered from \`$(basename "$vf")\` by \`ledger-prune.sh\`: the checker session died
before it could post this or apply its label, so the review below was written but never
published (issue #63). The verdict JSON it wrote:_

\`\`\`json
$(cat "$vf" 2>/dev/null)
\`\`\`"
    if gh pr comment "$pr" -R "$repo" --body "$body" >/dev/null 2>&1; then
      notes="$notes; posted the recovered verdict comment"
    else
      echo "  ⚠ could not post the recovered verdict comment on $repo#$pr" >&2
      notes="$notes; FAILED to post the recovered verdict comment"
    fi
  fi

  # (3) worker-court verdicts go back to draft (see the header — a label alone strands it).
  if [ "$label" = "resume" ]; then
    if [ "$(printf '%s' "$pj" | jq -r '.isDraft' 2>/dev/null || true)" = "true" ]; then
      notes="$notes; PR already draft"
    elif gh pr ready "$pr" -R "$repo" --undo >/dev/null 2>&1; then
      notes="$notes; flipped $repo#$pr back to draft"
    else
      echo "  ⚠ could not flip $repo#$pr back to draft — a ready PR labeled \`resume\` is dispatched to nobody" >&2
      notes="$notes; FAILED to flip the PR back to draft"
    fi
  fi
  printf 'published verdict %s: %s\n' "$v" "$notes"
  return 0
}

# rotate_verdict_file <verdict-file> — move an existing checker verdict JSON aside to a
# single `.prev.json` slot. Called by launch-checker.sh BEFORE it starts the session, so
# the canonical path is absent when a new generation begins. A pre-run helper (unlike its
# neighbours here) — it lives in this file because it must be reachable by the offline
# test tier without booting `claude`.
#
# WHY IT EXISTS (issue #49). The verdict path is fixed per (slug, PR) with no round or
# timestamp component, and nothing ever removed it, so on a RE-dispatch the previous
# round's verdict already sat at the canonical path from tick one. watch-dispatch.sh's
# terminal_state stats that file before consulting the ledger status, so a round-2 checker
# was reported terminal within seconds off a stale verdict on a possibly-many-commits-old
# head — and, worse, a round-2 checker that died before writing anything was reported as a
# clean verdict, so the crash was never surfaced at all. Clearing the path at dispatch is
# what restores the briefs' promise that "a crashed or interrupted dispatch is never
# watched in silence" for rounds 2+.
#
# WHY A ROTATION AND NOT AN `rm`. A re-dispatched checker already overwrites its
# predecessor in place, so no verdict history survives across rounds today; moving instead
# of deleting costs nothing and leaves one MORE local generation than exists now — exactly
# the one that matters when a fresh checker crashes before its first write. A single slot,
# not a timestamped archive: nothing prunes logs/, and the checker's PR comment carries the
# full verdict JSON, so GitHub is the durable history. Do not "simplify" this back to a
# delete, and do not let it grow a timestamped archive.
#
# watch-dispatch.sh reads ONLY the canonical path — `.prev.json` is deliberately invisible
# to it, so its verdict-file-wins precedence is untouched by this.
#
# `if` block, not `[ -f x ] && mv …`: a bare short-circuit as the last statement returns
# nonzero when the test is false and would abort a `set -e` caller silently (issue #23).
rotate_verdict_file() {
  local vf="$1"
  if [ -f "$vf" ]; then
    mv -f "$vf" "${vf%.json}.prev.json"
  fi
  return 0
}

# report_mutation <worktree> <baseline> — compare the worktree's current tracked-file
# state to a baseline captured before a checker ran; warn loudly if anything changed
# (a checker must touch nothing), else confirm clean. Lives here (not in the checker
# launcher) so the detached new-session body — a fresh shell that only re-sources THIS
# file — can call it.
report_mutation() {
  local worktree="$1" baseline="$2" after
  after="$(git -C "$worktree" status --porcelain 2>/dev/null || true)"
  if [ "$after" != "$baseline" ]; then
    echo "⚠ CHECKER MUTATED THE WORKTREE — investigate (it should touch nothing):" >&2
    diff <(printf '%s' "$baseline") <(printf '%s' "$after") >&2 || true
  else
    echo "mutation check: clean (checker touched no tracked files)."
  fi
}

# bootstrap_worktree_data <worktree> <raw_resolved> <working_clone> <dropbox_proj> <slug> [critical_paths] [derived_resolved]
# Provision a fresh worktree's machine-local (gitignored) data dirs BEFORE dispatch.
# <critical_paths> (optional, 6th arg) is a comma-separated list of worktree-relative
# paths a manifest declares load-bearing (issue #43); the gate below asserts every one.
# Sourced here (not duplicated in each launcher) so worker and checker bootstrap the
# SAME way — the checker re-runs pipeline stages that read those same trees, so it needs
# identical links. Two shapes:
#   (a) repo ships its own setup-symlinks.sh — run it IN the worktree so its per-tree
#       symlinks exist. ALWAYS in --worker mode: raw/+derived/ stay shared read-only,
#       output/ becomes a private worktree-local dir, so neither a worker nor a checker
#       ever races the main clone's outputs (the --worker contract the manifests specify).
#       A repo whose script ignores --worker (e.g. distance-decay-est) treats it as a
#       harmless no-op. We do NOT derive DROPBOX_PROJ from dirname(raw_resolved): that
#       assumed raw_resolved's parent == the DROPBOX_PROJ root the script expects, a
#       repo-layout-specific guess that DOUBLED the project path segment for
#       california-pesticides (raw_resolved ends in .../<proj>/data) and silently created
#       ZERO links (issue #25). The shipped scripts already default DROPBOX_PROJ to the
#       host's Dropbox layout, so we leave it alone unless the manifest sets an explicit
#       dropbox_proj. A SKIP/ERROR line means a link target was missing — surface it
#       LOUDLY: the old `|| echo` guard never fired because setup-symlinks.sh exits 0 even
#       when every link SKIPs, so an all-SKIP no-op looked like success.
#   (b) default template — one read-only data/raw symlink + a writable results dir, plus
#       a WRITABLE data/derived symlink when the manifest sets derived_resolved. derived/
#       is deliberately not read-only: a worker whose issue is "build the panel" has to be
#       able to write the thing it is writing the code for. The cost is that two concurrent
#       issues can race the same derived artifact — an accepted risk, documented rather
#       than defended with locking (research-template AGENTS.md > Data; hub #38).
#       Only branch (b) honors derived_resolved: a branch-(a) repo owns its whole symlink
#       layout in its own setup-symlinks.sh, and clobbering that with `ln -sfn` here would
#       fight the local escape hatch instead of deferring to it.
# CODE-ONLY EXCEPTION: a self-hosting manifest points raw_resolved at the repo root
# itself; when raw_resolved resolves to the same real path as working_clone there is NO
# distinct data tree, so scaffolding a self-referential data/raw symlink is spurious
# untracked cruft (it blocks worktree-prune --auto on merged worktrees) — skip it.
bootstrap_worktree_data() {
  local worktree="$1" raw_resolved="$2" working_clone="$3" dropbox_proj="$4" slug="$5"
  local critical_paths="${6:-}"   # comma-separated, relative to the worktree root (issue #43)
  local derived_resolved="${7:-}" # optional shared writable derived tree (hub #38); unset = no-op
  local raw_real clone_real own_script=0
  raw_real="$(cd "$raw_resolved" 2>/dev/null && pwd -P || echo "")"
  clone_real="$(cd "$working_clone" 2>/dev/null && pwd -P || echo "")"
  if [ -x "$worktree/setup-symlinks.sh" ]; then
    own_script=1
    local ss_out ss_rc=0
    # Separate declaration from assignment so the command-substitution exit status
    # isn't masked by `local` (a bash gotcha); capture it into ss_rc via `|| `.
    if [ -n "$dropbox_proj" ]; then
      ss_out="$( cd "$worktree" && DROPBOX_PROJ="$dropbox_proj" ./setup-symlinks.sh --worker 2>&1 )" || ss_rc=$?
    else
      ss_out="$( cd "$worktree" && ./setup-symlinks.sh --worker 2>&1 )" || ss_rc=$?
    fi
    printf '%s\n' "$ss_out"
    if [ "$ss_rc" -ne 0 ]; then
      echo "⚠ setup-symlinks.sh exited $ss_rc — $slug worktree may be missing data symlinks." >&2
    elif printf '%s\n' "$ss_out" | grep -qE '^[[:space:]]*(SKIP|ERROR)\b'; then
      # A SKIP/ERROR here is often a legitimately-optional tree (figures, usrds-proposal),
      # so this stays a quiet one-line note rather than a hard-fail — promoting it would
      # false-positive on every repo with an optional tree (issue #35's demotion rationale
      # still holds). The REAL gate for a branch-(a) repo is the manifest's critical_paths
      # (issue #43): declare the load-bearing links and the gate below asserts them.
      echo "note: setup-symlinks.sh reported SKIP/ERROR for one or more (optional) links (see output above)." >&2
    fi
    # derived_resolved is INERT on this path, and that has to be said out loud. This repo's own
    # script owns the whole data/ layout including data/derived, so nothing here provisions the
    # shared tree — yet the manifest key implies one, and the deny-hook's carveout (which is
    # manifest-driven, not bootstrap-driven) will happily permit writes to whatever data/derived
    # actually is. An operator who set the key would otherwise believe worktrees share a derived
    # tree while each quietly kept its own: the #25 class again, one layer up. Not a hard fail —
    # the repo's script may well provision derived perfectly well on its own terms — but never
    # silent.
    if [ -n "$derived_resolved" ]; then
      echo "⚠ derived_resolved is set but IGNORED for $slug: this repo ships its own" >&2
      echo "  setup-symlinks.sh, which owns the data/ layout (data/derived included), so" >&2
      echo "  nothing here links the shared tree. data/derived is whatever that script made." >&2
      echo "  Either provision the share inside that script, or unset derived_resolved in" >&2
      echo "  projects/$slug.yml so the manifest stops implying one." >&2
    fi
  elif [ -n "$raw_resolved" ] && [ "$raw_real" != "$clone_real" ]; then
    mkdir -p "$worktree/data/results"
    ln -sfn "$raw_resolved" "$worktree/data/raw"
    # WRITABLE, and shared across worktrees on purpose: expensive intermediates should not
    # be recomputed in every worktree. Guarded so an unset key changes nothing.
    if [ -n "$derived_resolved" ]; then
      local dlink="$worktree/data/derived"
      if [ ! -d "$derived_resolved" ]; then
        echo "⚠ derived_resolved is set but does not resolve to a directory: $derived_resolved" >&2
        echo "  Not linking data/derived — fix derived_resolved in projects/$slug.yml." >&2
      elif [ -d "$dlink" ] && [ ! -L "$dlink" ]; then
        # `ln -sfn` only declines to dereference when the destination is a SYMLINK. Against a
        # real directory it creates the link INSIDE it (data/derived/<basename>), so sharing
        # silently does not happen: the worker writes a private local dir and exits 0 — the
        # #25 failure class. An empty dir is a leftover `mkdir -p` and safe to replace; a
        # non-empty one means the repo tracks data/derived/ (e.g. a .gitkeep), which is
        # genuinely incompatible with pointing that path at shared storage. Deleting tracked
        # files to force it would dirty the worktree, so this is the operator's call, and the
        # dispatch stops before `claude` is spawned rather than sharing nothing quietly.
        if rmdir "$dlink" 2>/dev/null; then
          ln -sfn "$derived_resolved" "$dlink"
        else
          echo "✗ dispatch aborted: $dlink is a non-empty real directory, but this manifest" >&2
          echo "  sets derived_resolved, which requires data/derived to BE the shared symlink." >&2
          echo "  Linking over it would nest the link inside it and share nothing (issue #25 class)." >&2
          echo "  Resolve one way: stop tracking data/derived/ in the repo, or unset" >&2
          echo "  derived_resolved in projects/$slug.yml." >&2
          return 1
        fi
      else
        ln -sfn "$derived_resolved" "$dlink"
      fi
    fi
  fi

  # ── Critical-path gate (issue #35/#43 — defense-in-depth for #25) ──────────────
  # A worker/checker must NEVER start against a worktree whose load-bearing inputs
  # didn't link, or it computes on missing data and exits 0 (the #25 silent failure).
  # Mechanical host-side stop: both launchers run under `set -euo pipefail`, so a
  # non-zero return here aborts the dispatch BEFORE `claude` is spawned. It only
  # reads/stats paths — no writes under the raw tree. `--dry-run` never reaches here
  # (each launcher's dry-run block exits before bootstrap runs).
  #
  # Which paths get asserted, in precedence order:
  #   1. manifest `critical_paths` (the 6th arg) — the robust mechanism for repos whose
  #      load-bearing links are NOT the generic data/raw (issue #43). A branch-(a) repo
  #      that ships its own setup-symlinks.sh (e.g. distance-decay-est: "06 Raw_data" /
  #      "07 Dataclean" at the repo root) declares them here so it is genuinely gated,
  #      not merely warned. Every listed path must exist and resolve to a directory.
  #   2. unset → the generic data/raw invariant (#35), for branch-(b) template repos.
  # Exemptions apply to the DEFAULT (unset) path only: no raw_resolved configured, or a
  # CODE-ONLY manifest whose raw_resolved resolves to the working clone itself
  # (raw_real == clone_real), or a branch-(a) repo that declared nothing to assert (its
  # generic data/raw is never scaffolded — trust its own script + the SKIP/ERROR note).
  if [ -n "$critical_paths" ]; then
    local cp p tgt _oifs="$IFS"
    IFS=','
    for cp in $critical_paths; do
      IFS="$_oifs"
      while [ "${cp# }" != "$cp" ]; do cp="${cp# }"; done   # trim leading spaces (bash 3.2)
      while [ "${cp% }" != "$cp" ]; do cp="${cp% }"; done   # trim trailing spaces
      if [ -n "$cp" ] && [ ! -d "$worktree/$cp" ]; then
        p="$worktree/$cp"
        tgt="$(readlink "$p" 2>/dev/null || echo "$p")"
        echo "✗ dispatch aborted: a declared critical path does not resolve to a directory:" >&2
        echo "    $p -> ${tgt:-<missing>}" >&2
        echo "  A worker/checker would compute on missing inputs and exit 0 (issue #25/#35)." >&2
        echo "  Fix the link (or the tree it points at) — critical_paths in projects/$slug.yml." >&2
        return 1
      fi
      IFS=','
    done
    IFS="$_oifs"
    return 0
  fi

  # No critical_paths declared — fall back to the generic data/raw invariant (#35).
  # Skip when there is no distinct raw tree to assert: no raw_resolved, a CODE-ONLY
  # manifest (raw_real == clone_real), or a branch-(a) repo (which never scaffolds the
  # generic data/raw; its real inputs belong in critical_paths above).
  if [ -z "$raw_resolved" ] || { [ -n "$raw_real" ] && [ "$raw_real" = "$clone_real" ]; }; then
    return 0
  fi
  if [ "$own_script" = 1 ]; then
    echo "note: $slug ships its own setup-symlinks.sh but declares no critical_paths — no" >&2
    echo "  hard gate on its inputs. Declare the load-bearing links in critical_paths" >&2
    echo "  (projects/$slug.yml) to gate them; see the setup-symlinks.sh output above for SKIP/ERROR." >&2
    return 0
  fi
  local raw_link="$worktree/data/raw"
  if [ ! -d "$raw_link" ]; then          # missing, or a symlink whose target doesn't resolve
    local raw_target; raw_target="$(readlink "$raw_link" 2>/dev/null || echo "$raw_resolved")"
    echo "✗ dispatch aborted: the worktree's critical raw-data link does not resolve to a directory:" >&2
    echo "    $raw_link -> ${raw_target:-<missing>}" >&2
    echo "  A worker/checker would compute on missing inputs and exit 0 (issue #25/#35)." >&2
    echo "  Fix raw_resolved (or the raw tree it points at) in projects/$slug.yml." >&2
    return 1
  fi
  if [ -z "$(ls -A "$raw_link" 2>/dev/null)" ]; then
    echo "note: raw tree $raw_link resolves but is empty — proceeding (a legitimately-empty raw tree needs no .gitkeep)."
  fi
  return 0
}

# run_in_new_session <log> <ledger> <worktree> <kind> <mutation_baseline> -- <cmd...>
# Run <cmd...> in its OWN session (new sid + process group, no controlling tty), so a
# signal sent to the LAUNCHER's process group when the dispatching orchestrator session
# tears down can't reap it — the cause of workers dying with a 0-byte log (2026-06-22:
# isolated launches survived, but every worker dispatched by the headless orchestrator
# died, because it shared that session's group). macOS ships no setsid(1), so a tiny
# python os.setsid() shim leads the new session; `exec` preserves the pid, so the
# backgrounded pid the caller records ($!) IS the session leader — the pid finalize
# matches in the ledger. CALL IT BACKGROUNDED: `run_in_new_session ... & ; pid=$!`.
# Steps run inside the new session, all output appended to <log>: the command, then
# (checkers only) report_mutation, then finalize_dispatch. <mutation_baseline> is ""
# for workers.
run_in_new_session() {
  local log="$1" ledger="$2" worktree="$3" kind="$4" baseline="$5"; shift 5
  [ "${1:-}" = "--" ] && shift
  local cmd_q; printf -v cmd_q '%q ' "$@"
  local orch; orch="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # `exec` so this subshell becomes python (pid preserved) which os.setsid()s then
  # becomes bash (pid preserved) — the recorded $! is that session leader.
  exec env RIS_LOG="$log" RIS_LEDGER="$ledger" RIS_WT="$worktree" RIS_KIND="$kind" \
           RIS_BASE="$baseline" RIS_ORCH="$orch" RIS_CMD="$cmd_q" \
    python3 -c 'import os, sys
# Only setsid if we are NOT already a process-group leader (setsid would EPERM);
# if we already lead our own group we are already isolated from the parent group.
if os.getpid() != os.getpgid(0):
    os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' \
      bash -c '
source "$RIS_ORCH/dispatch-common.sh"
cd "$RIS_WT" && eval "$RIS_CMD" >>"$RIS_LOG" 2>&1 || true
[ "$RIS_KIND" = checker ] && report_mutation "$RIS_WT" "$RIS_BASE" >>"$RIS_LOG" 2>&1
finalize_dispatch "$RIS_LOG" "$RIS_LEDGER" "$$" "$RIS_WT" "$RIS_KIND" >>"$RIS_LOG" 2>&1'
}
