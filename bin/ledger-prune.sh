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
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ORCH/bin/config-common.sh"   # GITHUB_HANDLE (escalation @-mention)
LEDGER="${LEDGER:-$ORCH/ledger.md}"
[ -f "$LEDGER" ] || { echo "ledger-prune: no ledger at $LEDGER (nothing to do)"; exit 0; }

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

# Both no-clean-finish leads finalize_dispatch can post (dispatch-common.sh). They
# share ONE cap: from the operator's side "the worker was cut off" and "the worker
# exited without finalizing" are the same problem — an attempt that produced no
# finished work — and an exit-to-wait used to be invisible to WORKER_LIMIT entirely,
# so a wedged tmux job re-dispatched every cycle forever (issue #40).
NO_FINISH_LEADS = ("**Worker interrupted:", "**Worker incomplete:")

def trailing_interrupted_count(repo, num):
    """How many `**Worker interrupted:` / `**Worker incomplete:` comments (posted by
    finalize_dispatch, see dispatch-common.sh) sit at the END of the issue's comment
    history with nothing else after them. Any intervening comment (a milestone, a
    checker verdict, a human reply) resets it — the same 'per generation' idea
    CHECKER_LIMIT uses for verdict comments, so a genuinely-progressing issue never
    gets penalized for an interruption two rounds ago."""
    comments = issue_comments(repo, num)
    if comments is None:
        return None
    n = 0
    for c in reversed(comments):
        if (c.get("body") or "").startswith(NO_FINISH_LEADS):
            n += 1
        else:
            break
    return n

def escalate_needs_input(repo, num, n, limit):
    try:
        subprocess.run(["gh", "issue", "edit", str(num), "-R", repo,
                         "--add-label", "needs-input"], capture_output=True, timeout=15)
        subprocess.run(["gh", "issue", "comment", str(num), "-R", repo, "--body",
            f"🔁 Worker limit reached: {n} attempts in a row without a clean finish "
            f"(interrupted or incomplete), never reaching `ready` "
            f"(limit {limit}). Escalating to @{os.environ.get('GITHUB_HANDLE','')} — the "
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
# the operator instead of burning another worker budget on it.
WORKER_LIMIT = int(os.environ.get("WORKER_LIMIT", "4"))

def handle_no_clean_finish(repo, num):
    labs = issue_labels(repo, num)
    if labs is None or labs & {"needs-input", "checked-pass"}:
        return None  # already escalated or passed elsewhere — leave it alone
    n = trailing_interrupted_count(repo, num)
    if n is None:
        return None
    if n >= WORKER_LIMIT:
        escalate_needs_input(repo, num, n, WORKER_LIMIT)
        return f"WORKER_LIMIT reached ({n}/{WORKER_LIMIT}) — escalated to needs-input"
    # Cosmetic only (digest doesn't need it) — keeps the plain GitHub label view
    # legible for a human scanning issues outside the orchestrator's own digest.
    if "resume" not in labs and has_open_pr(repo, num) is True:
        relabel_resume(repo, num)
    return None

keep, pruned = [], []
for ln in lines:
    m = re.search(r"#(\d+)\s*\|\s*([^|]+?)\s*\|", ln)
    if not m:                      # blank/header line — preserve verbatim
        keep.append(ln)
        continue
    num, repo = int(m.group(1)), m.group(2).strip()
    pid = (re.search(r"pid\s+(\S+)", ln) or [None, None])[1]
    status = (re.search(r"status\s+(\S+)", ln) or [None, None])[1]
    is_checker = "check pr#" in ln.lower()   # checker entry: num is a PR, not an issue
    reasons = []
    if is_checker:
        if pr_done(repo, num):
            reasons.append("PR closed/merged")
    elif issue_closed(repo, num):
        reasons.append("issue closed")
    if pid_dead(pid):
        reasons.append(f"pid {pid} dead")
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
