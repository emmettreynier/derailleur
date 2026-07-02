#!/usr/bin/env bash
# board-digest.sh — deterministic board-state report for the orchestrator.
#
# Reads the FSE Research board (user project 3) + open ready-for-review PRs +
# recently-closed issues, diffs against the ledger, and emits a compact
# markdown digest. No LLM, no judgment: the script REPORTS, the orchestrator
# DECIDES what to dispatch. Safe to run standalone to eyeball board state.
#
# Network: 1 board call + 1 `gh search prs` (ready PRs, all repos) +
# 1 `gh search issues` (close dates, for the Done cap). Local: reads ledger.md.
#
# Env:
#   DONE_DAYS   how many days back to show closed items (default 7)
set -euo pipefail

PROJECT=3
OWNER="@me"
PR_OWNER="emmettreynier"
DONE_DAYS="${DONE_DAYS:-7}"
ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$ORCH_DIR/ledger.md"

command -v gh >/dev/null  || { echo "board-digest: gh not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "board-digest: python3 not found" >&2; exit 1; }

board_json="$(gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 200)"
closed_json="$(gh search issues --owner "$PR_OWNER" --state closed \
  --json number,repository,closedAt --limit 100 2>/dev/null || echo '[]')"

# Onboarded repos = those with a manifest; the orchestrator can only act on
# these, so the digest is scoped to them (a non-dispatchable issue it can't see
# can't be mis-dispatched). A footer reports what's outside the loop.
# (Open PRs are fetched per onboarded repo inside the script, with PR state.)
onboarded_slugs="$(ls "$ORCH_DIR/projects/"*.yml 2>/dev/null | xargs -n1 basename 2>/dev/null \
                     | sed 's/\.yml$//' | paste -sd, - || true)"

BOARD_JSON="$board_json" CLOSED_JSON="$closed_json" PR_OWNER="$PR_OWNER" \
LEDGER="$LEDGER" DONE_DAYS="$DONE_DAYS" ONBOARDED_SLUGS="$onboarded_slugs" python3 <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime, timezone, timedelta

board  = json.loads(os.environ["BOARD_JSON"]).get("items", [])
closed = json.loads(os.environ["CLOSED_JSON"])
pr_owner = os.environ.get("PR_OWNER", "")
done_days = int(os.environ["DONE_DAYS"])
now = datetime.now(timezone.utc)

# ---- labels the loop routes on (design: "Label vocabulary") -----------------
NEEDS_INPUT, RESUME, NEEDS_DEF, CHECKED_PASS, HOLD, BLOCKED = (
    "needs-input", "resume", "needs-definition", "checked-pass", "hold", "blocked")

def nwo(url):  # https://github.com/owner/repo -> owner/repo
    return re.sub(r"^https?://github\.com/", "", (url or "").rstrip("/"))

def short(url):  # -> repo (last path segment)
    return nwo(url).split("/")[-1] or "?"

# ---- normalize board items --------------------------------------------------
rows = []
for it in board:
    c = it.get("content", {}) or {}
    if c.get("type") != "Issue":
        continue
    rows.append({
        "num": c.get("number"),
        "title": (it.get("title") or c.get("title") or "").strip(),
        "body": c.get("body") or "",
        "status": it.get("status") or "(no status)",
        "project": it.get("project") or "—",
        "repo_url": it.get("repository") or c.get("repository") or "",
        "labels": set(it.get("labels") or []),
    })

# Scope the digest to onboarded repos — the orchestrator's operational world.
# Everything else is outside the loop (you handle it manually); summarized in a
# footer so the rest of the board is never silently invisible.
onboarded = {s for s in os.environ.get("ONBOARDED_SLUGS", "").split(",") if s}
def is_onboarded(repo_url): return short(repo_url) in onboarded
all_rows = rows
rows = [r for r in all_rows if is_onboarded(r["repo_url"])]
excluded_rows  = [r for r in all_rows if not is_onboarded(r["repo_url"])]
excluded_repos = sorted({short(r["repo_url"]) for r in excluded_rows})

def has(r, lab): return lab in r["labels"]

# ---- open PRs per onboarded repo, with state (the review pipeline) ----------
# Work-vs-review is carried by PR draft/ready state (design.md), so the digest
# must read it: an issue with an open PR is in the loop (working / in review),
# NOT a fresh dispatch candidate. A ready PR routes to the checker; the checker's
# verdict then lands as an issue label (checked-pass -> Emmett; resume -> worker).
def open_prs(repo):
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "-R", repo, "--state", "open", "--json",
             "number,title,url,isDraft,reviewDecision,headRefName,closingIssuesReferences,labels"],
            capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return []

open_pr_list = []                 # all open PRs across onboarded repos
pr_by_issue  = {}                 # (repo_nwo, issue_num) -> pr dict
for slug in sorted(onboarded):
    repo = f"{pr_owner}/{slug}" if pr_owner else slug
    for pr in open_prs(repo):
        pr["repo"] = repo
        pr["labels_set"] = {l.get("name") for l in (pr.get("labels") or [])}
        open_pr_list.append(pr)
        for ref in (pr.get("closingIssuesReferences") or []):
            pr_by_issue[(repo, ref.get("number"))] = pr

def issue_pr(r):  # the open PR that closes this issue, if any
    return pr_by_issue.get((nwo(r["repo_url"]), r["num"]))

# ---- ledger: local execution state GitHub doesn't record --------------------
# Tolerant of both the old (`… | dispatched TS`) and new (`… | pid P |
# dispatched TS | status S`) line formats.
inflight = {}   # (repo_nwo, num) -> {dispatched, pid, status}
try:
    with open(os.environ["LEDGER"]) as f:
        for ln in f:
            m = re.search(r"#(\d+)\s*\|\s*([^|]+?)\s*\|", ln)
            if not m:
                continue
            key = (m.group(2).strip(), int(m.group(1)))
            grab = lambda pat, d=None: (re.search(pat, ln) or [None, d])[1]
            inflight[key] = {                       # later lines win -> latest
                "dispatched": grab(r"dispatched\s+(\S+)", "?"),
                "pid":        grab(r"pid\s+(\S+)"),
                "status":     grab(r"status\s+(\S+)"),
            }
except FileNotFoundError:
    pass

def gh_issue(repo, num):
    """Title + state for an in-flight issue not on the board (bounded by the
    concurrency cap, so few calls). Degrades gracefully on failure."""
    try:
        r = subprocess.run(
            ["gh", "issue", "view", str(num), "-R", repo, "--json", "title,state"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return json.loads(r.stdout)
    except Exception:
        pass
    return None

def pid_alive(pid):
    """True/False if the worker process is running, None if unknowable."""
    if not pid or pid in ("-", "?"):
        return None
    try:
        pid = int(pid)
    except ValueError:
        return None
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True   # exists, owned by another user

# Classify every in-flight entry as live or stale, joining the title from the
# board (or a gh lookup for off-board issues). Stale = issue closed/Done, ledger
# status done/failed, or the pid is gone — these never count as live capacity.
onboard = {(nwo(r["repo_url"]), r["num"]): r for r in rows}
inflight_info = {}
for key, meta in inflight.items():
    repo, num = key
    r = onboard.get(key)
    title, reasons = None, []
    if r is not None:
        title = r["title"]
        if r["status"] == "Done":
            reasons.append("issue Done on board")
    else:
        info = gh_issue(repo, num)
        if info:
            title = (info.get("title") or "").strip()
            if info.get("state") == "CLOSED":
                reasons.append("issue closed")
        else:
            reasons.append("not on board / lookup failed")
    if meta.get("status") in ("done", "failed"):
        reasons.append(f"ledger status={meta['status']}")
    if pid_alive(meta.get("pid")) is False:
        reasons.append(f"pid {meta['pid']} not running")
    inflight_info[key] = {**meta, "title": title,
                          "stale": bool(reasons), "reasons": reasons}
live_keys = {k for k, v in inflight_info.items() if not v["stale"]}

def is_live_inflight(r):
    return (nwo(r["repo_url"]), r["num"]) in live_keys

def line(r, extra=""):
    labs = sorted(r["labels"])
    tag = " {" + ",".join(labs) + "}" if labs else ""
    flag = " ⚙ in-flight" if is_live_inflight(r) else ""
    t = r["title"]
    if len(t) > 72: t = t[:69] + "…"
    return f"- [{r['project']}] {short(r['repo_url'])}#{r['num']} — {t}{tag}{flag}{extra}"

def spec_excerpt(body):
    """The intake-gate signal for a dispatch candidate: a one-line lead plus its
    acceptance-criteria checkboxes. Absence of checkboxes is itself the signal
    that an issue is under-specified."""
    body = (body or "").strip()
    if not body:
        return ["    ⚠ empty body — under-specified"]
    lines = body.splitlines()
    lead = next((s for ln in lines
                 if (s := ln.strip()) and not s.startswith(("#", "-", "*", ">"))), "")
    checks = [s for ln in lines if re.match(r"- \[[ xX]\]", (s := ln.strip()))]
    out = []
    if lead:
        out.append("    " + (lead[:160] + "…" if len(lead) > 160 else lead))
    if checks:
        for c in checks[:8]:
            out.append("    " + (c[:118] + "…" if len(c) > 118 else c))
        if len(checks) > 8:
            out.append(f"    …(+{len(checks) - 8} more criteria)")
    else:
        out.append("    ⚠ no acceptance-criteria checkboxes")
    return out

out = []
def w(s=""): out.append(s)

w(f"# Board digest — {now.strftime('%Y-%m-%d %H:%M UTC')}")
w(f"_Scoped to onboarded repos ({', '.join(sorted(onboarded)) or 'none'}) — the orchestrator's dispatchable world._")
w()

# ---- classify open PRs into review-pipeline buckets -------------------------
# Routing labels live on the ISSUE (matching resume/needs-input convention), so a
# PR is classified by its closing issue's labels, not its own:
# draft, no live worker, no needs-input/hold/blocked -> WORKER'S COURT. This is
# structural, not label-dependent: a draft PR nobody is actively working is
# unambiguously something a worker should (re)pick up, whether it got there via
# checker feedback (`resume`), Emmett's hand-back, or a crash mid-run that never
# got a chance to set any label at all. Folded directly into dispatch candidates
# below (2026-07-01) — a prior "stalled, needs a label to be dispatchable" bucket
# silently stranded first-time-interrupted workers (see design.md discussion).
# draft+live         -> a working worker (already shown in the In-flight section).
# ready+checked-pass (or human-approved) -> Emmett's merge gate (his court).
# ready+needs-input -> checker escalated -> shown via the issue's needs-input row.
# ready, otherwise  -> checker's court (awaiting/needing a checker).
def short_repo(nwo_str): return nwo_str.split("/")[-1]

# closing-issue labels for a PR (from the board rows) — where routing labels live.
issue_labels = {(nwo(r["repo_url"]), r["num"]): r["labels"] for r in rows}
def pr_issue_labels(pr):
    out = set()
    for ref in (pr.get("closingIssuesReferences") or []):
        out |= issue_labels.get((pr["repo"], ref.get("number")), set())
    return out

def pr_line(pr, extra=""):
    t = (pr.get("title") or "").strip()
    if len(t) > 66: t = t[:63] + "…"
    closes = ",".join(f"#{r.get('number')}" for r in (pr.get("closingIssuesReferences") or [])) or "—"
    return f"- {short_repo(pr['repo'])}#{pr['number']} — {t}  (closes {closes}){extra}  {pr.get('url','')}"

def pr_has_live_worker(pr):
    return any((pr["repo"], ref.get("number")) in live_keys
               for ref in (pr.get("closingIssuesReferences") or []))

def pr_issue_row(pr):  # the board row for whichever issue this PR closes
    for ref in (pr.get("closingIssuesReferences") or []):
        r = onboard.get((pr["repo"], ref.get("number")))
        if r:
            return r
    return None

approved, awaiting_check, worker_court_prs = [], [], []
for pr in open_pr_list:
    ilabs = pr_issue_labels(pr)
    if pr.get("isDraft"):
        if not pr_has_live_worker(pr) and not (ilabs & {NEEDS_INPUT, HOLD, BLOCKED}):
            worker_court_prs.append(pr)   # nobody working it, nothing parking it -> dispatch
    elif CHECKED_PASS in ilabs or pr.get("reviewDecision") == "APPROVED":
        approved.append(pr)               # checker passed (or human-approved) -> merge gate
    elif NEEDS_INPUT in ilabs or RESUME in ilabs:
        pass                              # escalated (needs-input) or handed back (resume)
                                          # -> surfaced via its issue row; not the checker's court
    else:
        awaiting_check.append(pr)         # ready, not passed, not handed back -> checker's court

# ---- NEEDS EMMETT (his court — surface, never dispatch) ----------------------
ni  = [r for r in rows if has(r, NEEDS_INPUT)]
nd  = [r for r in rows if has(r, NEEDS_DEF)]
w(f"## Needs Emmett — human's court ({len(ni)+len(nd)+len(approved)}) · surface to him, never dispatch")
w(f"**Checker-passed PRs — ready to merge ({len(approved)}):**")
[w(pr_line(p)) for p in approved] or w("- none")
w(f"**needs-input ({len(ni)}):**")
[w(line(r)) for r in ni] or w("- none")
w(f"**needs-definition ({len(nd)}):**")
[w(line(r)) for r in nd] or w("- none")
w()

# ---- DISPATCH CANDIDATES (worker's court) -----------------------------------
# resume = a draft PR with no live worker and nothing parking it (needs-input/
# hold/blocked) — derived structurally above from PR + ledger state, so it
# catches checker-bounced work, Emmett hand-backs, AND crashed-first-attempt
# workers uniformly, with no dependency on a `resume` label having been written.
# A bare `resume` label with no open PR (rare — e.g. hand-labeled) is included
# too, defensively. Plus fresh actionable issues with NO open PR at all (an open
# PR means the issue is already in the loop — working or in review).
resume, _seen = [], set()
for pr in worker_court_prs:
    r = pr_issue_row(pr)
    if r and (k := (nwo(r["repo_url"]), r["num"])) not in _seen:
        _seen.add(k); resume.append(r)
for r in rows:
    if has(r, RESUME) and issue_pr(r) is None and (k := (nwo(r["repo_url"]), r["num"])) not in _seen:
        _seen.add(k); resume.append(r)
actionable = [
    r for r in rows
    if r["status"] in ("In Progress", "Up Next")
    and not has(r, HOLD) and not has(r, BLOCKED)
    and not has(r, NEEDS_DEF)        # already adjudicated under-specified -> Emmett's court
    and not is_live_inflight(r) and not has(r, RESUME)
    and issue_pr(r) is None          # an open PR => in the loop, not dispatchable
]
w(f"## Dispatch candidates — worker's court ({len(resume)+len(actionable)})")
w(f"**resume — revisions to re-dispatch ({len(resume)}):**")
[w(line(r)) for r in resume] or w("- none")
# Each actionable candidate carries its acceptance criteria so the orchestrator
# can apply the intake gate from the digest alone (dig deeper only if unsure).
w(f"**actionable, no open PR (Up Next / In Progress) ({len(actionable)}):**")
if actionable:
    for r in actionable:
        w(line(r))
        for ex in spec_excerpt(r["body"]):
            w(ex)
else:
    w("- none")
w()

# ---- IN REVIEW (PR pipeline — the loop's court, not Emmett's, not dispatch) --
w(f"## In review — PR pipeline ({len(awaiting_check)})")
w(f"**Ready PRs awaiting checker ({len(awaiting_check)})** · _orchestrator-cycle dispatches a checker on these; pass → checked-pass, changes → resume+draft_")
[w(pr_line(p, f"  [{p.get('reviewDecision') or 'no-review'}]")) for p in awaiting_check] or w("- none")
w()

# ---- IN FLIGHT (ledger): live workers vs stale entries ----------------------
live  = {k: v for k, v in inflight_info.items() if not v["stale"]}
stale = {k: v for k, v in inflight_info.items() if v["stale"]}

def inflight_title(v):
    t = v["title"] or "(title unavailable)"
    return t[:69] + "…" if len(t) > 72 else t

w(f"## In flight — ledger (live {len(live)} · stale {len(stale)})")
if live:
    for (repo, num), v in sorted(live.items()):
        pidpart = f" · pid {v['pid']}" if v.get("pid") and v["pid"] not in ("-", "?") else ""
        w(f"- {repo.split('/')[-1]}#{num} — {inflight_title(v)} — dispatched {v['dispatched']}{pidpart}")
else:
    w("- none live")
if stale:
    w(f"**stale — safe to prune ({len(stale)}):**")
    for (repo, num), v in sorted(stale.items()):
        w(f"- {repo.split('/')[-1]}#{num} — {inflight_title(v)}  ⚠ {', '.join(v['reasons'])}")
if not inflight_info:
    w("- none")
w()

# ---- BOARD BY STATUS --------------------------------------------------------
# Actionable statuses get full listings; the long tail (Backlog/Ideas) is
# collapsed to per-project counts to keep the digest compact — those aren't
# dispatch-eligible until promoted to Up Next anyway.
DETAIL  = ["In Progress", "Up Next", "Blocked"]
SUMMARY = ["Backlog", "Ideas"]
by_status = {}
for r in rows:
    by_status.setdefault(r["status"], []).append(r)
from collections import Counter
w("## Board by status")
for st in DETAIL + [s for s in by_status if s not in DETAIL + SUMMARY + ["Done"]]:
    grp = by_status.get(st)
    if not grp:
        continue
    w(f"### {st} ({len(grp)})")
    for r in sorted(grp, key=lambda x: (x["project"], short(x["repo_url"]), x["num"] or 0)):
        w(line(r))
    w()
for st in SUMMARY:
    grp = by_status.get(st)
    if not grp:
        continue
    per = Counter(r["project"] for r in grp)
    breakdown = " · ".join(f"{p} {n}" for p, n in sorted(per.items()))
    w(f"### {st} ({len(grp)}) — {breakdown}")
    w()

# ---- HELD / BLOCKED (excluded from dispatch) --------------------------------
held    = [r for r in rows if has(r, HOLD)]
blocked = [r for r in rows if has(r, BLOCKED)]
if held or blocked:
    w(f"## Excluded from dispatch (hold {len(held)} · blocked {len(blocked)})")
    for r in held:    w(line(r, "  [hold]"))
    for r in blocked: w(line(r, "  [blocked]"))
    w()

# ---- RECENTLY CLOSED (Done, last N days; ignore for dispatch) ---------------
closed_at = {}   # (nwo, num) -> closedAt
for c in closed:
    rp = c.get("repository", {})
    key = (rp.get("nameWithOwner") or "", c.get("number"))
    closed_at[key] = c.get("closedAt")

cutoff = now - timedelta(days=done_days)
recent = []
for r in rows:
    if r["status"] != "Done":
        continue
    ts = closed_at.get((nwo(r["repo_url"]), r["num"]))
    keep = True
    if ts:
        try:
            keep = datetime.fromisoformat(ts.replace("Z", "+00:00")) >= cutoff
        except ValueError:
            keep = True
    if keep:
        recent.append((ts or "?", r))
w(f"## Recently closed — Done, last {done_days}d (ignore for dispatch) ({len(recent)})")
if recent:
    for ts, r in sorted(recent, reverse=True):
        w(line(r, f"  closed {ts[:10] if ts and ts!='?' else '?'}"))
else:
    w("- none")
w()

# ---- FOOTER: what's outside the loop (not onboarded) ------------------------
w("---")
if excluded_rows:
    w(f"_Outside the loop: {len(excluded_rows)} open board issue(s) across "
      f"{len(excluded_repos)} non-onboarded repo(s) ({', '.join(excluded_repos)}) — "
      f"handled manually. Onboard a repo (manifest in projects/) to bring it into the loop._")
else:
    w("_All open board repos are onboarded._")

print("\n".join(out))
PY
