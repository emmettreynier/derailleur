# Orchestrator — Design

[Home](README.md)

---

**Status:** design (not yet built) · **Verified against:** Claude Code `2.1.183`

A local, autonomous agentic system that dispatches work described in GitHub issues, verifies it, and surfaces only the decisions that need *you* — so your time goes to research judgment instead of babysitting a session and hitting "1".

## The problem this solves

Today: you babysit a single Claude session — mostly waiting, approving tool calls — and to fill the waiting you open more sessions in other projects, paying a heavy **cross-project context-switch** cost (pesticides → solar is the expensive swap). The goal is to invert that: agents grind in the background while you do value-add work, and you engage in batched, per-project review windows.

## Core principles

These are the load-bearing decisions; everything below follows from them.

1. **GitHub is the only source of truth.** Issues, PRs, labels, comments, board fields. Every other artifact (ledger, logs, inbox view) is a disposable derivative regenerated from GitHub. A crash loses nothing.
2. **Intent is yours; context is the repo's.** An agent booted in a repo inherits its `CLAUDE.md`, code, and data for free (context). It cannot infer *what you want and what counts as done* (intent). So **authoring issues is always you**; agents only execute issues that already carry a contract.
3. **Deterministic gathering, model judgment.** Cheap scripts (`gh` + `jq`) collect and bucket board state; tokens are spent only on judgment (what to dispatch, whether work is correct). Same philosophy as RTK.
4. **Fresh-wake, durable-state.** The orchestrator holds no long-lived context. It wakes, rebuilds state from GitHub + a small local ledger, acts, exits. No compacting fragile context across time.
5. **Raw data is sacred.** Each repo's `raw/` is read-only — even to you. Everything downstream is deterministically regenerable from code, so the blast radius of any rogue worker is "redo some compute," never "lose data."
6. **Human merge gate, always.** A passed PR enters your inbox awaiting *your* merge. You are a research advisor evaluating outputs and asking probing questions — not a line-by-line code reviewer.
7. **Group by project, not by task.** Your scarce resource is domain attention; the inbox clusters everything for one project so you load a domain once and clear it.

## Actors

| Actor | Lifespan | Context | Driver | Job |
|---|---|---|---|---|
| **Orchestrator** | standing (scheduled), local | board-only (no science) | `launchd` + you | Route the ball: intake-gate issues, dispatch workers/checkers, maintain the ledger |
| **Worker** | ephemeral, in-repo | deep (booted from repo) | orchestrator | Implement one issue → draft PR with results summary → signal ready or escalate |
| **Checker** | ephemeral, in-repo | deep | orchestrator | Verify a ready PR against the issue's acceptance criteria |
| **Advisor console** | interactive, in-repo | deep | **you** | Author/remediate issues, review PRs, ask probing questions, post answers |
| **You** | — | — | — | Write the playbook (issues), make research judgments, merge |

Workers, checkers, and the advisor console are **the same boot recipe** — a fresh Claude in repo X with its `CLAUDE.md` + the relevant issue/PR. Only the role and driver differ. There is exactly **one standing component** (the orchestrator); everything else is ephemeral or interactive. No standing per-project managers — cross-issue sequencing lives as issue dependencies + sprint planning.

## How a session is assembled (boot recipe)

Mechanically, every worker/checker/console session is one `claude` invocation composed from markdown + flags:

- **Project context** — the repo's `CLAUDE.md` auto-loads when the session boots in the repo.
- **Role brief** — an editable markdown file (`briefs/worker-brief.md`, `briefs/checker-brief.md`, `briefs/orchestrator-brief.md`): the protocol layer (lifecycle, signals, results-summary contract). The launcher renders it — strips the header comment, fills `{{TOKENS}}` from the manifest/PR — and passes the result via `--append-system-prompt`. Briefs live in files (not heredocs) so they're easy to edit without touching the launcher.
- **The task** — the issue, fetched at runtime (`gh issue view N`) or passed as the user prompt.
- **Task know-how** — the relevant **skill** (see Skill library), selected by matching the issue's **Type** field.

So: repo `CLAUDE.md` (auto) + role brief (appended file) + issue (fetched) + skill (invoked). The brief stays short because the skills carry the detail.

## The loop — "route the ball"

The orchestrator's entire job is routing one ball, observed each wake from GitHub state:

- **Ball in worker's court** → dispatch/continue a worker. Triggers: a new well-specified issue; your *answer* to an escalation; your *probing question* on a PR.
- **Ball in checker's court** → a PR marked **ready** → dispatch a checker.
- **Ball in your court** → `needs-input` (a question) or a checker-passed PR (awaiting merge) or `needs-definition` (under-specified issue). This is your **inbox**.

Your probing question and a worker's escalation are the *same mechanism in opposite directions*: a human comment (content) + a label flip (signal) puts the ball back in the worker's court.

## Worker lifecycle & signals

A worker runs to completion and exits in exactly one state, signalled on GitHub (no board-status changes needed):

- **Still working** → draft PR open. (No signal.)
- **Ready for review** → worker marks the PR **ready** (un-drafts). Orchestrator → dispatch checker.
- **Needs input** → worker adds `needs-input` + a question comment, leaves PR draft. Orchestrator → inbox.
- **Ran out of budget / rate-limited / crashed (a hard stop)** → no clean exit, so no `/handoff` and no Stop-hook nudge — `finalize_dispatch` (in `bin/dispatch-common.sh`) does the cleanup instead: pushes any local commits immediately (don't wait for a future redispatch to find them), records `interrupted-*` in the ledger, and posts a `**Worker interrupted: <status>` comment on the issue. `bin/board-digest.sh` treats a draft PR with no live worker as the worker's court structurally — no label required — so it's redispatched next cycle automatically. If it keeps happening, `WORKER_LIMIT` (default 4 consecutive interruptions, mirrors `CHECKER_LIMIT`) escalates it to `needs-input` instead of retrying forever. *(This replaced an earlier, never-implemented "retries once" design — see git history around 2026-07-01.)*

## The results-summary contract

Every finished PR's description must let you advise *without reading the diff*. Required sections (the checker enforces they exist and the outputs are real):

- **Goal** — what the issue asked for.
- **What I did** — 2–3 sentences.
- **What I ran** — script/command, reproducible.
- **Key outputs** — the actual table/figure/numbers, committed and *shown*, not "see code." Exact form is defined per-issue (a cleaning task ≠ a robustness task ≠ a lit review).
- **Judgment calls / open questions** — so your probing questions have somewhere to land.
- **Outcome** — a typed self-report of what happened: `shipped` (a change satisfies the issue), `no-op` (the issue was already satisfied / a dup — nothing to change, here's why), or `blocked` / `handed-off` (couldn't finish — paired with `needs-input` or a `/handoff` state comment). Gives the digest and checker a structured signal instead of inferring intent from a draft/ready bit alone — and makes the "nothing needed doing" case a first-class, non-suspicious result. *(Adapted from Gas City's typed `work_outcome`.)*

The per-task output expectations are defined **in the issue's acceptance criteria** at authoring time — which is why good issues are core to your job.

**Enforced by a `Stop` hook, not just the brief** *(added 2026-06-21)*. The brief tells a worker to leave a trail; a hook makes it mechanical. `host/hooks/worker-stop-guard.sh` (a `Stop` hook injected per-worker by `bin/launch-worker.sh` via `--settings`, with the issue # and repo baked into its command) refuses to let a worker session end unless it has finished *legibly*: either a **PR exists for its branch** (shipped/working) or the issue carries **`needs-input`** (blocked/escalated). Otherwise it returns `{"decision":"block"}` with a reason that re-states the two exits, and the worker keeps going. It's a **single firm nudge** — the hook honors `stop_hook_active` (the documented guard against Stop-hook loops), so it blocks at most once; a worker that ignores the nudge is caught downstream (no PR → invisible to the digest/checker) rather than trapped burning budget. Scoped to workers only — checkers have a different contract (no Edit/Write, they don't open PRs).

## Checkers

Verification is a single **LLM checker at PR-ready** (the deliberate signal): substantive verification against the issue's acceptance criteria plus output sanity — re-running/inspecting real outputs, not trusting the PR's claim. It triggers on **PR marked ready**, not on commit frequency.

*(A deterministic per-push GitHub Actions CI tier was considered and dropped: the data model is machine-local and gitignored, so a cloud runner has no data to run the analysis against — CI could only do static parse/lint checks, which aren't worth the per-repo wiring and private-repo minutes. The mechanical "does it run on real data" check stays local, where the worker and checker both have the data.)*

**Route by whose court the follow-ups are in, not just by pass/fail** *(decided 2026-06-20)*. The checker first tags each finding with an `actor` — `worker` (a concrete fix: bug, unmet criterion, cleanup, a doable improvement) or `emmett` (a research-judgment call / FYI only Emmett can settle). Then: **pass** (criteria met, no findings) and **pass_with_findings** (criteria met; *every* remaining finding is `actor=emmett`) → your merge gate; **changes_requested** (≥1 `actor=worker` finding, even if criteria technically pass) and **fail** (criterion unmet) → `resume` (worker takes another pass); **blocked** → `needs-input`. The crucial rule: an `actor=emmett` finding is **never** bounced to a worker — so once the worker has ground down all the worker-actionable items, only Emmett's calls remain → `pass_with_findings` → his court, and the loop terminates on its own. A `CHECKER_LIMIT` (default 4 rounds) is a pure backstop against a runaway worker↔checker ping-pong: if it's ever hit, the orchestrator escalates the PR to `needs-input` rather than re-checking forever. Rounds are counted **per review generation, not over the PR's lifetime** *(fixed 2026-06-22)* — a `pass`/`pass_with_findings`/`blocked` verdict hands the ball to Emmett and ends a generation, so once he reviews and bounces it the next check is round 1 again. (Counting lifetime verdict comments wrongly tripped the limit on a PR that had legitimately round-tripped through Emmett's court several times.)

**Signalling is by issue label + comment, not by GitHub review** *(decided 2026-06-20)*. The checker authenticates as the same account that authored the PR (the worker uses Emmett's `gh`), and GitHub refuses to let an account formally approve / request-changes on its **own** PR. So the checker never posts a formal review verdict — it posts its verdict as a **comment** (led by `**Checker verdict: <verdict>**` so rounds can be counted) and sets an **issue label**: `checked-pass` (criteria met → Emmett's merge gate; PR left ready), `resume` + un-ready (worker-actionable changes), or `needs-input` (blocked). Routing labels live on the **issue** (matching `resume`/`needs-input`), so the digest classifies a PR by its closing issue's labels. **The checker never merges** — merging is always Emmett's. (A genuine second-identity bot PAT, which *could* post real approvals, was considered and deferred as unnecessary overhead for a solo researcher.)

**Structured verdict (so the orchestrator routes deterministically).** The checker emits its review as a small JSON object alongside the prose comment — `verdict ∈ {pass, pass_with_findings, changes_requested, fail, blocked}`, `findings[]` (each `severity` / `actor` / `title` / `file` / `line`), `evidence` (commands run / files inspected), and `failure_class ∈ {none, transient, hard}`. `verdict` maps to label/PR-state without parsing prose: `pass`/`pass_with_findings` → `checked-pass` (merge gate), `changes_requested`/`fail` → `resume` + un-ready, `blocked` → `needs-input`. *(Pattern adapted from Gas City's `mol-review-quorum` lane contract.)*

**Checkers give feedback, never do the work — enforced mechanically:** a checker boots with a restricted tool set (`Read`, `Bash` to run tests/inspect, `gh` to comment + set labels) and **no `Edit`/`Write`**. It literally cannot modify code. **Belt-and-suspenders:** the checker records a mutation baseline (`git status --porcelain`) on entry and again before exit, and reports the delta — so a clean checker run *proves* it touched nothing, and any accidental write surfaces instead of riding along into the PR.

**Checker ↔ worker communication is asynchronous, through GitHub** (the worker has already exited): the checker posts PR review comments; the orchestrator re-dispatches a worker on `resume` that `/pickup`s, reads them, and addresses them — the same comment-is-content / label-is-signal handshake as your own review.

## Wake digest + hook

A deterministic script `bin/board-digest.sh` (`gh project item-list 3 --owner @me --format json` + `jq`) emits a compact markdown digest grouped by the board **Status** field, annotated with **Project** and **Repository**, plus computed buckets: **ready-for-review PRs**, **needs-input issues**, **resume issues**, **needs-definition issues**, and a diff against the ledger (what's in-flight). `Done` is capped to "closed in last N days" and ignored for dispatch.

The digest is injected via an **env-gated `SessionStart` hook** (`ORCHESTRATOR=1`) so the orchestrator boots pre-loaded with board state and zero tool calls — and so it never fires in your normal interactive sessions. The script **reports**; the orchestrator **decides** what to dispatch (judgment stays in the model).

## State & durability

- **Truth:** GitHub (issues/PRs/labels/comments/board).
- **Ledger:** `ledger.md` — the one thing GitHub doesn't record: `issue # → branch / log path / pid / dispatched-at / status`. Used to avoid double-dispatch, count concurrency, and detect crashes. Worker lines are `- #N | …`; checker lines `- check pr#N | …` (the leading form keeps checkers out of the worker concurrency-count regex). `status ∈ {dispatched, done, interrupted-ratelimit, interrupted-budget, interrupted-error}` — set to `dispatched` at launch and flipped by the launcher's post-run `finalize_dispatch` (see below). `bin/ledger-prune.sh` drops closed-issue / dead-pid entries at the start of every cycle and, when it drops one whose status is `interrupted-*`, says so (so a cutoff isn't silent).
- **Logs:** `logs/<slug>-issue-N.log` / `-pr-N.log` — each session's stdout, for *your* debugging. The durable record is the PR.
- **Worktrees:** `<worktrees_dir>/issue-N` (per-project, from the manifest) — one per dispatched issue, created idempotently by `bin/launch-worker.sh` and *reused* across re-dispatches (so an interrupted worker's local commit is found and pushed next cycle). They are pure derivatives (principle #1/#4) and can be large (a checked-out repo plus generated outputs — a single merged solar-income worktree measured ~7 GB), but nothing reclaimed them, so the dir grew without bound as branches merged. `bin/worktree-prune.sh` reclaims them in **two modes**:
  - **`--auto`** (run first in every cycle, beside `bin/ledger-prune.sh`) — non-interactive, deletes a worktree only when its work is **provably on the default branch**: its branch has a **merged PR**. That merged bit is the authoritative signal *precisely because git ancestry isn't* — a squash merge leaves the branch tip unreachable from `main`, so `git merge-base --is-ancestor` would wrongly say "unmerged." Anything **not merged** — even a closed-not-planned issue — is **kept and reported**, never auto-deleted; auto mode will not touch work that didn't land on `main`.
  - **interactive** (the default when run raw, needs a terminal) — lists every worktree with disk use and status (✓ merged+clean vs. · needs-confirm), and you pick which to remove. You *can* delete an unmerged or in-flight one, but it takes a per-item `y/N` confirmation that names the risk.
  
  The guarded invariant in both modes is the one thing a worktree can hold that GitHub can't — **local-only state** (uncommitted edits, unpushed commits): auto mode refuses on it outright; interactive mode surfaces it and makes you confirm. It also skips a live in-flight worktree (a matching ledger line). On removal it drops the now-orphaned local branch (`branch -D` — squash-merge defeats the safe `-d` test). **`--force` (auto only)** overrides *one* thing: a removal blocked solely by leftover **untracked, non-gitignored** files (stray outputs) — it never overrides uncommitted edits or unpushed commits. Recovery if ever wrong is free: a re-dispatch recreates the worktree from `origin`. *(Portability landmine, fixed 2026-06-22: macOS ships **bash 3.2**, where expanding an **empty array** under `set -u` — e.g. `"${flag[@]}"` when no `--force` — is a fatal `unbound variable` error; it silently aborted every removal. These scripts must branch on the flag rather than build-then-expand an optional-arg array.)*

**Interruption is detected, not assumed-success** *(added 2026-06-20)*. `claude --output-format json` can exit with `subtype:"success"` yet `is_error:true` + `api_error_status:429` ("session limit") — a rate-limit cutoff that leaves work **committed locally but unpushed**. So a single shared `finalize_dispatch` (in `bin/dispatch-common.sh`, sourced by both launchers) runs when the session exits: it `classify_result`s the real fields (rate-limit / budget / error / clean), records the verdict in the ledger `status`, and on interruption (worker only) pushes any commits ahead of upstream immediately — rather than waiting for a future redispatch to find them — and posts a `**Worker interrupted: <status>` comment on the issue. **Recovery is automatic and needs no label to survive** *(revised 2026-07-01 — see below)*: `bin/board-digest.sh` treats a draft PR with no live worker as the worker's court purely from PR + ledger state, so the next cycle redispatches it regardless of whether any label was ever set. `WORKER_LIMIT` (`bin/ledger-prune.sh`, counting consecutive `**Worker interrupted:` comments) stops that from looping forever on an issue that can never finish unattended.

*Two bugs that defeated this detection were fixed 2026-06-22* (recovery worked all along via the worktree+label self-healing above — but the **detection/recording half was silently dead**): (1) under `set -euo pipefail`, claude's **nonzero exit** on an interrupted run (budget cap / rate limit / error) aborted the launcher subshell *before* `finalize_dispatch` — i.e. it only ever ran on the clean exit-0 path where its interruption handling wasn't needed; fixed with `|| true` on the claude invocation in both the foreground and detached paths of both launchers. (2) `classify_result` read "the last non-empty log line," but the checker's `report_mutation` appends *after* the result JSON, so it parsed that prose and returned `unknown` — meaning a checker could never record `done`; fixed by scanning lines in reverse for the last `type=="result"` object. (Earlier "proven live" 429 recovery was real for *recovery*; the ledger `status`/warning it should have left was the part that wasn't landing.)

**Detached dispatches run in their own session** *(added 2026-06-22)*. A worker/checker dispatched by the headless orchestrator shared that orchestrator session's process group — so when the orchestrator exited, the teardown signal to its group reaped the in-flight worker *mid-run*, leaving work uncommitted and a **0-byte log** (the whole subshell was hard-killed before `finalize_dispatch`, so the interruption wasn't even recorded). Diagnosed live: launches isolated in a plain shell survived, but every worker dispatched *by the headless orchestrator* died — 2/2. Fix: `run_in_new_session` (in `bin/dispatch-common.sh`, used by both launchers' detached paths) runs the guarded command in **its own session** via a tiny `python os.setsid()` shim (macOS ships no `setsid(1)`); `exec` preserves the pid, so the pid recorded in the ledger *is* the session leader that `finalize_dispatch` later matches. The new-session body runs claude → (checker only) `report_mutation` → `finalize_dispatch`, all appended to the log. Verified: the leader gets its own pgid distinct from the launcher's and survives a launcher-group `SIGTERM`, and a real cycle-dispatched worker then ran to a clean, recorded finish. *(Foreground `--foreground` dispatches are supervised and unaffected — they aren't orphaned.)*

## Safety model

Workers run unattended (no human to approve prompts), so guardrails are **defense in depth** — only the first layer trusts the model to behave:

**Layer 1 — OS:** `raw/` is **read-only** (perms / read-only symlink) — workers read `raw/`, write only to `processed/`/`out/` in the worktree; `--add-dir` scopes filesystem reach to just the worktree + data path. (For *dropbox-native* repos that can't be chmod'd without breaking coauthor scripts, this protection is delivered by the Layer-2 deny-hook over the manifest's `raw_paths` instead — see Portability.)

**Layer 2 — Claude Code (deterministic, harness-enforced):**
- `--permission-mode bypassPermissions` so workers never stall on an unanswerable prompt, **but**
- a **`PreToolUse` hook** *denies* dangerous calls before they run — `rm -rf`, writes outside the worktree, `git push … main`, force-pushes, and writes/deletes under the manifest's raw prefixes (`raw_resolved` + `raw_paths`). Writes under a manifest `output_paths` entry are an explicit **allow-carveout** over that raw denylist — needed when a repo's writable outputs live *inside* a shared raw tree (e.g. `distance-decay-est`'s per-survey `outputs/`/`results/` nested under the Dropbox-symlinked `07 Dataclean`);
- a **`Stop` hook** refuses to let a worker finish until protocol is met (PR opened, results-summary present), feeding the gap back;
- `--disallowedTools` blocks destructive patterns; checkers additionally drop `Edit`/`Write` (see Checkers).

**Layer 3 — GitHub (server-side backstop):** branch protection requires a PR and forbids direct pushes to `main`. Even a fully rogue agent with the token **cannot** corrupt `main` or self-merge. *Caveat (found 2026-06-19):* GitHub gates branch protection on **public repos or a paid plan** — on a **private free-plan repo** (most research repos, e.g. `solar-income`) the API returns 403 and this layer is **unavailable**. Where it's off, the bulletproof guarantee is gone and Layer 2's push-to-`main`/force-push denials are the only thing keeping a worker off `main` (model-trusted only insofar as the hook's pattern-matching is complete). For private repos that need the real server-side guarantee, options: GitHub Pro; make the repo public; or give the worker a **feature-branch-scoped token/deploy key** that physically cannot push to `main`. To confirm per repo: `gh api repos/<owner>/<repo>/branches/main/protection` (403 = unprotected).

**Layer 4 — budget:** a per-session `--max-budget-usd` cap on every role + the orchestrator's concurrency cap bound runaway cost. Each role's cap is tunable *(per-role budgets added 2026-06-22)*: the launchers default to **worker $10.00** (`bin/launch-worker.sh`, raised from $4.00 on 2026-07-01 after a legitimately large multi-spec issue hit the old cap mid-run) and **checker $3.00** (`bin/launch-checker.sh`), overridable per dispatch by the `--budget` arg, or session-wide by the `WORKER_BUDGET` / `CHECKER_BUDGET` env vars (precedence: `--budget` arg > env > default). `bin/orchestrator-cycle.sh` reads `WORKER_BUDGET` / `CHECKER_BUDGET` (same defaults) and threads them into every checker call and the worker dispatch line, so a single env var raises the ceiling for a whole cycle. The **orchestrator** session itself is capped by `BUDGET` (default $0.50) — small, since it only reads the digest and routes; raise it if a cycle with many candidates gets cut off mid-decision.

The **orchestrator** gets its own guardrails: board-only (no `--add-dir` to any data), no `Edit`/`Write`, its own budget cap — it can dispatch and label, nothing else.

**Standing guards (hygiene backstop, brief-layer)** *(added 2026-07-13)*. Beyond the destruction-safety layers above, both briefs carry a fixed integrity/hygiene bar every PR must clear regardless of what its issue asked for — because the guards live in the protocol layer, not individual issues: (1) no secrets/credentials/absolute local paths/PII in the diff, (2) the changed entry point runs clean from a fresh session, (3) seeds set where sampling/simulation/bootstrap is introduced, (4) affected docs updated (or a stated "no docs needed" reason), (5) raw inputs untouched. The worker self-verifies 1–4 and attests in the results-summary (guard 5 is already covered worker-side by the raw-data rules + deny-hook); the checker independently verifies 1–5 on every PR, and a violation is an `actor=worker` finding that bounces the PR (`changes_requested`/`fail`) even when the issue's explicit criteria all pass. This is model-trusted on the worker side and independently checked — not a harness-enforced layer.

## Running the cycle

Every command for running the system by hand — one full pass, previewing the board
digest, dispatching a single worker/checker, reclaiming worktree disk — plus the
tunable env vars (`CAP`, `BUDGET`, `WORKER_BUDGET`, `CHECKER_BUDGET`, `CHECKER_LIMIT`,
`WORKER_LIMIT`) lives in the [README](README.md) (*Usage*), which is the single source
of truth for operating the system. This design doc explains only *why* the cycle is
shaped as it is: the ledger/worktree prune → checkers → workers ordering falls out of
state & durability, the concurrency cap out of the inbox model, and the per-role
budgets out of the safety model — each covered in its own section here.

## Scheduling & power

The schedule fires the **cycle**, not a bare `claude -p`. The real entrypoint is `bin/run-cycle.sh` (a launchd-safe wrapper around `bin/orchestrator-cycle.sh`); `bin/schedule.sh` installs/manages the launchd agent and the wake chain. (The `bin/schedule.sh` subcommands themselves — `install`/`live`/`plan-only`/`run`/`status`/`pause`/`resume`/`uninstall` — are documented in the [README](README.md) *Enable the scheduled loop* / *Day-to-day scheduler commands*; this section is the design rationale behind them.)

- **Wake:** a macOS **`launchd`** agent (label from `orchestrator.conf`'s `LAUNCHD_LABEL`, rendered from the `host/LaunchAgents/orchestrator.plist` template into `~/Library/LaunchAgents/` by `bin/schedule.sh install`) fires `bin/run-cycle.sh` at fixed `StartCalendarInterval` slots — **night-heavy centers 20/23/02/05/08** — to shift the grind off the daytime session-limit window. launchd (over `cron`) runs a missed slot once on wake.
- **Jitter (±15 min):** launchd has no native jitter, so synchronized on-the-hour fires would stampede shared servers in lockstep with everyone else's cron. The plist therefore fires **15 min early** (:45 of the prior hour) and passes `--jitter`, which makes `bin/run-cycle.sh` sleep a random **0–30 min** (`caffeinate -i` holds the Mac awake through it) — so each cycle actually starts uniformly within **±15 min of its center**. Jitter applies only to scheduled fires; manual `bin/schedule.sh run` and any `--dry-run` are immediate. Window is `JITTER_MAX_SECS` (default 1800).
- **`bin/run-cycle.sh`** does the three things a bare schedule gets wrong: (1) sets a known **PATH** (launchd's stripped env can't find `claude`/`gh`/the python.org `python3`); (2) the **usage gate** (below); (3) arms the next pmset wake so the chain self-perpetuates. It tees a human log to `logs/cycle.log`.
- **Usage-limit gate (overnight lever):** dispatches run on Emmett's Claude **subscription** (no API key), so they share his **5-hour rolling session limit** — overnight work shifts *when* the pool is spent, freeing the daytime window (it doesn't add quota; a *weekly*-cap hit can't be helped by timing). There is **no way to query the reset ahead of time** — Claude only reveals it *reactively*, as prose in the 429 result (`"resets 7:40pm"`). `record_usage_reset` (in `bin/dispatch-common.sh`, called from `finalize_dispatch` on a worker/checker rate-limit and from `bin/run-cycle.sh` for the orchestrator session) parses that into `state/usage-reset`; `bin/run-cycle.sh` then **defers** any fire inside the exhausted window (a skipped fire costs nothing) and resumes automatically once the marker passes.
- **Manual trigger:** a hand-run cycle kickstarts the agent through the *identical* launchd path (not a separate code path), so what you test by hand is what fires on the timer; a `--dry-run` variant plans inline without spending. Status inspection surfaces the same state the scheduler acts on — agent state, next pmset wake, the usage gate, and the cycle-log tail.
- **Plan-only → live is a toggle, not a plist edit:** the mode lives in `state/mode` (machine-local), which `bin/run-cycle.sh` reads on every fire; missing/non-`live` → plan-only, so a fresh install never dispatches for real until you opt in. Flipping it (via the README's `live`/`plan-only` subcommands) needs no file editing and no `launchctl` reload — effective on the next cycle. An explicit `--dry-run`/`ORCH_DRY=1` still forces plan-only regardless. Pausing/resuming stop and restart firing entirely (lighter than uninstall; for being away).
- **Concurrency cap:** start at **2–3** workers (`CAP`), tied to *your review bandwidth*, not CPU.
- **Sleep & power (honest):** launchd won't wake a sleeping Mac on its own. `bin/schedule.sh install` seeds **`pmset`** wakes — a daily `repeat wakeorpoweron MTWRF` bootstrap plus a self-arming one-off `schedule wake` before each slot (pmset holds only one *repeat*/day, hence the chain). Needs the Mac **on power**; a closed lid still sleeps between wakes, which is fine — it wakes ~2 min before each slot, fires, and sleeps again. In-flight workers freeze if the Mac sleeps mid-run; the next cycle recovers them via worktree reuse + retained label. True 24/7-while-closed would want a dedicated always-on host.

## The inbox

**Not** an LLM-generated markdown (rejected: stale/hallucination risk, duplicates truth). Instead:

- **A saved board view "Needs Me"** — filtered to (`needs-input` ∨ PR-ready-for-merge ∨ `needs-definition`), **grouped by the Project field**. Deterministic, *is* the truth, every row clicks straight to the work. You clear one project fully, then switch domains once.
- **A batched push** twice a day (sit-down + evening) with deterministic counts from the digest script — e.g. *"Pesticides: 2 merge, 1 answer · Energy: 1 define."* No per-event pings (that recreates babysitting). One real-time exception: the orchestrator itself crashed / everything blocked.

## Response handshake

The orchestrator never interprets your prose. **Comment = content (for the worker to read); label = signal (for the orchestrator to route on).**

- **Answer an escalation:** post comment **+** swap `needs-input` → `resume`. Next wake: digest sees `resume` → dispatch worker → `/pickup` → reads your answer → continues → clears label.
- **Send a PR back:** comment your question + un-ready the PR + `resume`.
- **Merge:** you click merge (terminal; board auto-moves to Done via existing workflow).
- **Define a bounced issue:** you + advisor console write the acceptance criteria/outputs; it becomes dispatch-ready.

The advisor console can do the comment + label flip in one step when you say "post this to #N."

## Intake gate

When the orchestrator considers dispatching, it judges whether the issue carries a real contract (goal, acceptance criteria, defined outputs). If materially under-specified, it **does not dispatch** — it labels `needs-definition` and drops it in your inbox. It never drafts the content itself (no intent). The orchestrator may auto-answer only **mechanical** escalations (e.g. obvious repo routing); anything substantive passes straight to you — a wrong auto-answer is worse than a question.

## Verified CLI capabilities (`claude` 2.1.183)

| Need | Mechanism |
|---|---|
| Headless run | `-p / --print` (+ `--output-format json`, `--json-schema` for parseable results) |
| Cost ceiling | `--max-budget-usd` *(note: `--max-turns` does **not** exist in this version)* |
| Durable background sessions | native **background-agents** daemon (`~/.claude/{daemon,jobs,tasks}`); `claude agents --json` lists active sessions for scripting *(exact headless dispatch path TBD at build)* |
| Isolated workspace | `--worktree [name]` (built in); `--tmux` to attach and watch a worker live |
| Autonomy level | `--permission-mode` (`bypassPermissions` / `acceptEdits` / `auto` / `dontAsk` / `default` / `plan`) |
| Constrain commands | `--allowedTools` / `--disallowedTools` (e.g. `"Bash(git *)" Edit`) |
| Scope filesystem | `--add-dir` |
| Inject protocol | `--append-system-prompt` / `--system-prompt`; `--agents` for role defs |
| Survive overload unattended | `--fallback-model` |

No OS-sandbox CLI flag exists; confinement = `--add-dir` + allow/deny tools + permission mode + OS-level read-only raw data.

## Label vocabulary (proposed — redline me)

The determinism of the whole loop rests on these. Digest script keys on:

- `needs-input` — worker/checker escalated; your court (answer).
- `resume` — you've answered (or a checker requested changes); worker's court. *(As of 2026-07-01, no longer load-bearing for dispatch: `bin/board-digest.sh` derives worker's-court status structurally from PR draft/live-worker state, so a crashed-before-labeling worker is still picked up. The label is now a legibility aid — set for humans scanning the plain issue list — not the dispatch signal itself.)*
- `needs-definition` — the orchestrator's verdict after evaluating: under-specified; your court (author criteria).
- `hold` — *your* pre-emptive "not ready, don't dispatch." The digest **hard-excludes** it (no orchestrator judgment). Chains with the above: `hold` while you draft → remove it → orchestrator then either dispatches or bounces with `needs-definition`.
- `blocked` — waiting on something external.
- *Work vs review* is carried by **PR draft/ready state**, not a label.

## Skill library (always WIP)

Skills encode "how Emmett likes task-type X done," lifting global conventions (`data.table`/`collapse`, `here`, `qs2`, `=`) up to procedure level. They serve **everything** on the boot recipe — autonomous workers, the advisor console, and ordinary interactive sessions — so the library is independently valuable and **perpetually a work in progress**, growing as patterns recur.

- **Scope:** user-level (`~/.claude/skills/`) for cross-project research conventions (every repo's workers get them); per-repo (`.claude/skills/`) for project-specific ones.
- **Selection:** the worker brief says "match the issue's **Type** field to the relevant skill"; the skill carries the detail, keeping the brief lean.
- **Seed set:** `write-like-emmett` (exists); add `clean-data`, `causal-spec`/`run-regression`, `robustness-checks`, `lit-review`, `make-figures`, `referee-report`, … authored via `skill-creator`.

## Portability & bootstrap

The system splits into portable and machine-local parts; the goal is that a new machine (or project) is reproduced from the repo + GitHub, never from memory.

- **Portable (this repo + GitHub):** design, scripts, templates (including the sanitized per-project manifest template, `templates/project.yml`), briefs, hooks, skills — plus GitHub-side state (labels, the board view, branch settings).
- **Machine-local — the bits that "make it tick":** Claude Code hook/permission config (`~/.claude/settings.json`), the rendered `launchd` plist (`~/Library/LaunchAgents/`), the per-operator identity config (`orchestrator.conf`, gitignored — name/handle/PR-owner/launchd-label so a labmate runs their own instance), user skills (`~/.claude/skills/`), the out-of-Dropbox working clones, `gh`/Dropbox auth, and the **filled-in per-project manifests** (`projects/*.yml`, gitignored — they carry real repo names, local clone/data paths, and confidentiality notes).

To make the machine-local pieces reproducible, their canonical copies live **in the repo** (`host/`) and are linked into place by a bootstrap script:

- **`bin/install.sh`** — host bootstrap: symlinks hooks/skills/plist into `~/.claude/` and `~/Library/LaunchAgents/`, checks deps (`gh`, `jq`, `claude`). (The new-machine sequence — clone → `install.sh` → `gh auth login` — is in the [README](README.md) *Install*.)
- **`bin/new-project.sh <repo>`** — per-project onboarding: creates labels, ensures the board view covers it, sets up the out-of-Dropbox working clone, scaffolds the manifest.
- **`README.md`** — getting-started guide: host + per-project checklists, including the irreducibly-manual steps (board-view membership, Dropbox "available offline" pinning, coauthor buy-in for shared-repo branch protection).

**Per-project manifest** (`projects/<repo>.yml`) is the onboarding unit — repo, board Project, archetype, clone/worktree locations, data root, and the raw-path deny-list. The manifests themselves are **machine-local (gitignored)** since they carry real repo names, local paths, and confidentiality notes; what's *tracked* is the sanitized shape in `templates/project.yml`, which `bin/new-project.sh` renders into a fresh manifest. So onboarding on a new machine is `bin/new-project.sh` (scaffold from the template) + filling its TODOs — or copying an existing manifest across by hand.

**Project archetypes** (a manifest field):
- **git-native** (preferred) — repo is git-only; `data/` is a symlink to a Dropbox location (or in-repo if small/non-restricted). Worktrees trivial; raw protected by perms or the deny-hook.
- **dropbox-native** (legacy/coauthored, e.g. solar-income) — repo lives in Dropbox; workers operate from an out-of-Dropbox clone; raw pinned "available offline" + protected by the deny-hook. Used when coauthors require the Dropbox-native layout.

## Build order (de-risked: conventions first, automation last)

- **Phase 0 — conventions, manual dry-run** ✅ *(solar-income pilot; full loop proven by hand → PR #4 merged)*. Labels, results-summary template, raw-data deny-hook, worker launcher; per-project manifest as the onboarding unit. (Branch protection is unavailable on private free-plan repos — Layer-3 gap below.)
- **Phase 1 — digest script + hook** ✅. `bin/board-digest.sh` + env-gated `SessionStart` hook + `bin/launch-orchestrator.sh`. The digest reports (board state, in-flight ledger diff, dispatch candidates with acceptance criteria, the PR review-pipeline); the orchestrator decides.
- **Phase 2 — worker harness** ✅. `bin/launch-worker.sh` + `briefs/worker-brief.md`: headless worker on one issue with worktree, deny-hook, safety flags, budget cap; draft PR + results-summary contract; fresh session per dispatch.
- **Phase 3 — checker** ✅ *(built & proven)*. `bin/launch-checker.sh` + `briefs/checker-brief.md`: an LLM checker on a ready PR, restricted to Read/Bash/`gh` (no Edit/Write) + a launcher-side mutation baseline; emits the structured verdict JSON and routes by **actor of the remaining findings** (worker-actionable → `resume`; only Emmett's calls left → `checked-pass`), with a `CHECKER_LIMIT` round backstop. `bin/orchestrator-cycle.sh` dispatches it deterministically on ready, not-yet-passed PRs. Validated end-to-end on solar-income PR #5 (worker↔checker round-trips converged to `checked-pass`). The **`Stop` hook** (worker exit-contract enforcement, above) is built & unit-validated 2026-06-21. (Per-push GitHub Actions CI dropped — see Checkers: no cloud data to run against.)
- **Phase 4 — orchestrator automation** ✅ *(scheduled launcher built; ships in plan-only mode)*. `bin/orchestrator-cycle.sh` (prune → dispatch checkers → dispatch workers up to `CAP`) + `bin/ledger-prune.sh`; the scheduled launcher is `bin/run-cycle.sh` + `bin/schedule.sh` + the `host/LaunchAgents/orchestrator.plist` template (label from `orchestrator.conf`), with a night-heavy schedule, a pmset wake chain, and the subscription usage-limit deferral gate (above). Mode (plan-only vs live) is a machine-local toggle in `state/mode`, flipped by `bin/schedule.sh live`/`plan-only` (no plist edit); default plan-only.
- **Phase 4.1 — resilience hardening** ✅ *(2026-07-01, prompted by issue #16 stranding after a budget-cap interruption)*. Three gaps found by tracing that failure end-to-end: (1) `bin/board-digest.sh` derives worker's-court status structurally from PR draft/live-worker state instead of requiring a `resume` label to have been written at exactly the right moment — closes the "first-attempt crash, no label to inherit" hole; (2) `finalize_dispatch` now pushes local commits and posts a `**Worker interrupted:` issue comment immediately on any hard stop, rather than waiting for a future redispatch to notice; (3) `WORKER_LIMIT` (default 4, mirrors `CHECKER_LIMIT`) counts consecutive interruption comments and escalates to `needs-input` instead of retrying forever. Also fixed in the same pass: a repo onboarded by hand-adding a manifest (skipping `bin/new-project.sh`) silently missing its label set — `bin/setup-labels.sh` is idempotent and safe to re-run on any onboarded repo if in doubt.
- **Phase 5 — scale.** Add projects; tune cadence, concurrency, push counts; consider an always-on host if overnight grinding proves worth it.

## Open / to-redline

- Whether the advisor console is a defined skill/alias vs just "an interactive session in the repo."
- Per-task **Expected Outputs** snippet library (cleaning / robustness / lit review / …) for issue authoring — direction: lives in the skill library, #19.
- **Source of truth is revisitable, not fixed.** Principle #1 (GitHub-only) buys zero-infra durability *today*, but it's a v1 choice, not a vow. If scale or DAG-shaped multi-step work outgrows issues+labels, a dedicated work store (e.g. Gas City's bead model, or a file-backed equivalent) is on the table — the migration cost is the open question, not the principle. Worth re-checking once the manual dry-run (Phase 0) exposes where issues+labels actually strain.
