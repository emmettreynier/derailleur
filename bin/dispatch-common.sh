#!/usr/bin/env bash
# dispatch-common.sh — shared post-run helpers for launch-worker.sh / launch-checker.sh.
# SOURCED, not executed. Its job: make an INTERRUPTED dispatch (rate limit, budget
# cap, crash) record itself as interrupted instead of looking like a clean finish.
#
# Why this exists: `claude --output-format json` can exit with subtype "success" yet
# is_error:true + api_error_status:429 ("session limit") — a rate-limit cutoff that
# leaves work committed locally but UNPUSHED. Keying completion off `subtype` alone
# (as a naive read does) mistakes that for done. classify_result reads the real fields.

# classify_result <log> -> echoes: done | interrupted-ratelimit | interrupted-budget
#   | interrupted-error | unknown.  Parses the final JSON result line in the log.
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

# finalize_dispatch <log> <ledger> <pid> <worktree> <kind> — run AFTER the claude
# process exits: classify the outcome, record it in the ledger, and on interruption
# warn loudly + report unpushed commits the re-dispatch will recover. `pid` is "-"
# for foreground runs (the ledger line isn't pid-keyed there; the warning still fires).
finalize_dispatch() {
  local log="$1" ledger="$2" pid="$3" worktree="$4" kind="$5"
  local st; st="$(classify_result "$log")"
  _ledger_set_status "$ledger" "$pid" "$st"
  if [ "$st" = "done" ]; then
    echo "$kind finished cleanly."
    return 0
  fi
  echo "⚠ $kind did NOT finish cleanly — status: $st" >&2
  # A session-limit cutoff means the whole subscription window is spent — park the
  # reset so the scheduler defers the next fire instead of dispatching into a 429.
  [ "$st" = "interrupted-ratelimit" ] && record_usage_reset "$log"

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

  # Leave a durable, countable trail on the issue — the same comment-is-signal
  # convention the checker uses for its verdicts (`**Checker verdict: …`). A
  # WORKER_LIMIT check in ledger-prune.sh counts trailing `**Worker interrupted:`
  # comments to catch a runaway interrupted-retry loop before it burns budget
  # forever on an issue that can never finish unattended.
  if [ "$kind" = "worker" ]; then
    local repo issue
    repo="$(git -C "$worktree" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
    issue="$(git -C "$worktree" branch --show-current 2>/dev/null | sed -nE 's/^issue-([0-9]+)$/\1/p')"
    if [ -n "$repo" ] && [ -n "$issue" ]; then
      gh issue comment "$issue" -R "$repo" \
        --body "**Worker interrupted: $st**${push_note}. Not a failure by itself — the orchestrator recovers this automatically next cycle; repeated interruptions on this issue with no clean finish will eventually escalate to \`needs-input\`." \
        >>"$log" 2>&1 || echo "  ⚠ could not post interruption comment on $repo#$issue" >&2
    fi
  fi
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

# bootstrap_worktree_data <worktree> <raw_resolved> <working_clone> <dropbox_proj> <slug>
# Provision a fresh worktree's machine-local (gitignored) data dirs BEFORE dispatch.
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
#   (b) default template — one read-only data/raw symlink + a writable results dir.
# CODE-ONLY EXCEPTION: a self-hosting manifest points raw_resolved at the repo root
# itself; when raw_resolved resolves to the same real path as working_clone there is NO
# distinct data tree, so scaffolding a self-referential data/raw symlink is spurious
# untracked cruft (it blocks worktree-prune --auto on merged worktrees) — skip it.
bootstrap_worktree_data() {
  local worktree="$1" raw_resolved="$2" working_clone="$3" dropbox_proj="$4" slug="$5"
  local raw_real clone_real
  raw_real="$(cd "$raw_resolved" 2>/dev/null && pwd -P || echo "")"
  clone_real="$(cd "$working_clone" 2>/dev/null && pwd -P || echo "")"
  if [ -x "$worktree/setup-symlinks.sh" ]; then
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
      echo "⚠ setup-symlinks.sh could not create every link (SKIP/ERROR above) — the $slug" >&2
      echo "  worktree is missing data symlinks; a stage that reads them will fail at run" >&2
      echo "  time. Check dropbox_proj / raw_resolved in projects/$slug.yml (issue #25:" >&2
      echo "  this used to fail silently — an all-SKIP run still exits 0)." >&2
    fi
  elif [ -n "$raw_resolved" ] && [ "$raw_real" != "$clone_real" ]; then
    mkdir -p "$worktree/data/results"
    ln -sfn "$raw_resolved" "$worktree/data/raw"
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
