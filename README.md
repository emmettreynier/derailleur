<p align="center">
  <img src="derailleur.png" alt="derailleur" width="360">
</p>

# derailleur

A local, autonomous system that dispatches GitHub-issue work to headless Claude Code
workers, verifies it with an LLM checker, and surfaces only the decisions that need you.

**The problem it solves:** without it, you babysit a single Claude session — mostly
waiting, approving tool calls — and fill the waiting by opening more sessions in other
projects, paying a heavy cross-project context-switch cost. Derailleur inverts that:
agents work in the background on well-specified GitHub issues while you do value-add
work, and you engage in batched, per-project review windows instead.

GitHub is the only source of truth (issues, PRs, labels, comments, board fields) — the
ledger, logs, and digest are disposable derivatives regenerated from it, so a crash
loses nothing. A human merge gate is non-negotiable: nothing in this system merges a
PR, that's always you.

> **Note for labmates:** operator identity is still partly hardcoded to this repo's
> maintainer (GitHub owner, board project number, the `launchd` label). Fully
> parameterizing it so you can run your own instance is tracked in
> [#4](https://github.com/emmettreynier/derailleur/issues/4).

## Getting started

### Requirements

- [`gh`](https://cli.github.com/) (authenticated: `gh auth login`)
- [`jq`](https://jqlang.org/)
- [`claude`](https://claude.com/claude-code) (Claude Code CLI)
- `python3`, `git`
- Dropbox, if any onboarded project uses the `dropbox-native` archetype (below)

### Install (one-time, per machine)

1. Clone this repo.
2. Install the dependencies above.
3. `gh auth login`.
4. `./bin/install.sh` — dep-checks (`gh`/`jq`/`claude`/`python3`/`git`), asserts the
   in-repo host hooks are executable, creates `logs/` + `state/`, and scaffolds
   `orchestrator.conf` from `orchestrator.conf.example`. Idempotent.
5. Fill in `orchestrator.conf` with your identity (`OPERATOR_NAME`, `GITHUB_HANDLE`,
   `PR_OWNER`, `LAUNCHD_LABEL`, `BOARD_PROJECT`) — it's gitignored and per-operator, so a
   labmate runs their own instance without editing code. Every field is required; the
   scripts abort with guidance if any is blank.
6. Verify: `claude --version`, then a dry run: `./bin/launch-orchestrator.sh --dry-run`.

This does **not** register anything in `~/.claude/` — the host hooks are passed to
each dispatch by in-repo path, so your normal interactive Claude Code sessions
elsewhere on the machine stay untouched. See `design.md` → *Portability & bootstrap*
for the full split between what's portable (this repo + GitHub) and what's
machine-local.

### Onboard a project

1. Choose an **archetype**: `git-native` (preferred — repo is git-only, data is a
   symlink) or `dropbox-native` (coauthored/legacy — repo lives in Dropbox).
2. `./bin/new-project.sh <owner/repo> [--archetype …] [--clone …] [--worktrees …]` —
   creates the label set, ensures an out-of-Dropbox working clone + worktrees dir,
   and scaffolds `projects/<repo>.yml`. Idempotent.
3. Fill the scaffolded manifest's TODOs — board `project`, `raw_resolved`, and
   confirm `data_root`/paths.
4. Add the repo to the board + the "Needs Me" view (manual, GitHub Projects UI).
5. **`dropbox-native` only:** pin the raw data "Available offline" in Dropbox
   (manual).
6. **Shared repos:** get coauthor buy-in before enabling `main` branch protection;
   otherwise rely on the agent's deny-hook for "no pushes to `main`."
7. Author one well-specified issue (clear goal + acceptance criteria + defined
   outputs) and dry-run a worker by hand: `./bin/launch-worker.sh <slug> <issue#> --dry-run`.

A few steps are irreducibly manual (not CLI-scriptable): GitHub board view
membership/filters, Dropbox "Available offline" pinning, `gh`/Dropbox
authentication, and coauthor buy-in for shared-repo branch protection.

### Enable the scheduled loop (optional)

Once you trust a project's setup, you can let the orchestrator run itself on a
timer instead of triggering it by hand:

```bash
./bin/schedule.sh install       # registers the launchd timer, ships in plan-only mode
./bin/schedule.sh run --dry-run # trigger one cycle by hand — free, dispatches nothing
./bin/schedule.sh live          # flip the switch that lets scheduled runs actually spend
```

It runs night-heavy (roughly 8pm/11pm/2am/5am/8am on weeknights, jittered) so it
spends your Claude usage while you're asleep instead of competing with you during the
day. See `design.md` → *Scheduling & power* for the full mechanics (usage-limit
backoff, `pmset` wake chain, concurrency cap).

## Usage

### Run one orchestration pass by hand

```bash
./bin/orchestrator-cycle.sh              # real pass: prune -> dispatch checkers -> dispatch workers
./bin/orchestrator-cycle.sh --dry-run    # plan only — nothing dispatched, nothing spent
```

Tunable by env var, e.g. `WORKER_BUDGET=6 ./bin/orchestrator-cycle.sh`:

| Var | Default | What it does |
|---|---|---|
| `CAP` | `2` | Max workers in flight at once (tied to your review bandwidth, not CPU). |
| `BUDGET` | `0.50` | Orchestrator session budget (USD). |
| `WORKER_BUDGET` | `10.00` | Per-worker session budget (USD). |
| `CHECKER_BUDGET` | `3.00` | Per-checker session budget (USD). |
| `CHECKER_LIMIT` | `4` | Max checker rounds per review generation before escalating to `needs-input`. |
| `WORKER_LIMIT` | `4` | Max consecutive interrupted worker attempts before escalating to `needs-input`. |

To preview the board digest the orchestrator boots with — deterministic, free,
dispatches nothing:

```bash
./bin/launch-orchestrator.sh --dry-run   # prints the board digest (the orchestrator's whole view)
```

### Dispatch one role directly

Bypasses the cycle's intake gate — use when you've already decided. Both reuse the
worktree idempotently and run detached by default:

```bash
./bin/launch-worker.sh  <repo-slug> <issue#> [--dry-run] [--foreground] [--budget USD] [--fallback MODEL]
./bin/launch-checker.sh <repo-slug> <pr#>    [--dry-run] [--foreground] [--budget USD] [--fallback MODEL]

# e.g. land a resume issue with extra headroom, watched live:
./bin/launch-worker.sh solar-income 1 --budget 5 --foreground
```

### Reclaim worktree disk

```bash
./bin/worktree-prune.sh                  # interactive: list every worktree (disk + status), pick which to remove
./bin/worktree-prune.sh --auto           # non-interactive: remove merged+clean worktrees, report the rest
./bin/worktree-prune.sh --auto --dry-run # report only, remove nothing
./bin/worktree-prune.sh --auto --force   # also drop worktrees blocked solely by stray untracked files
```

### Day-to-day scheduler commands

```bash
./bin/schedule.sh status        # timer state, current mode, next wake, usage gate, recent log
./bin/schedule.sh live          # let scheduled runs dispatch for real (spend)
./bin/schedule.sh plan-only     # back to no-spend (runs still happen, just plan)
./bin/schedule.sh run           # run one cycle right now (respects the current mode)
./bin/schedule.sh run --dry-run # run one cycle right now in plan-only mode (free)
./bin/schedule.sh pause         # stop firing entirely (e.g. while away) — instant, reversible
./bin/schedule.sh resume        # start firing again after a pause
./bin/schedule.sh uninstall     # remove completely (unregister timer, cancel wakes)
```

### How to read the results

Every finished PR carries a fixed **results-summary** (Goal / What I did / What I
ran / Key outputs / Judgment calls / Outcome — see `templates/pr-results-summary.md`)
so you can review it like a research advisor, without reading the diff. Your
inbox is a saved GitHub Projects board view ("Needs Me"), grouped by project,
filtered to what actually needs you: `needs-input`, a checker-passed PR awaiting
merge, or `needs-definition`.

## Repository structure

```
derailleur/
├── design.md                    Full design doc — architecture, safety model, build history
├── orchestrator.conf.example     Per-operator identity template (copy -> orchestrator.conf, gitignored)
├── projects/                     Per-project manifests (the onboarding unit)
│   └── *.yml                        machine-local, gitignored (see templates/project.yml)
├── briefs/                       Role protocol briefs
│   ├── worker-brief.md
│   ├── checker-brief.md
│   └── orchestrator-brief.md
├── templates/
│   ├── project.yml                  Tracked, sanitized manifest shape (new-project.sh renders it)
│   └── pr-results-summary.md        The results-summary PR template workers fill in
├── host/hooks/                   PreToolUse / Stop / SessionStart hooks (the safety layer)
├── host/LaunchAgents/            launchd plist template for the scheduled loop
├── bin/                          All shell entrypoints (invoke as ./bin/<script>.sh)
│   ├── install.sh                One-time host bootstrap
│   ├── new-project.sh             Per-project onboarding
│   ├── setup-labels.sh            (Re-)creates the label set on a repo
│   ├── orchestrator-cycle.sh      One full dispatch pass (prune -> checkers -> workers)
│   ├── run-cycle.sh               Scheduled-loop entrypoint (launchd/pmset wiring)
│   ├── schedule.sh                Install/manage the launchd schedule
│   ├── launch-worker.sh           Dispatch a headless worker on one issue
│   ├── launch-checker.sh          Dispatch a headless checker on one PR
│   ├── launch-orchestrator.sh     Boot an (interactive or scheduled) orchestrator session
│   ├── dispatch-common.sh         Shared post-run helpers, sourced by both launchers
│   ├── config-common.sh           Loads operator identity from orchestrator.conf (sourced)
│   ├── ledger-prune.sh            Drop stale ledger entries at the start of every cycle
│   ├── worktree-prune.sh          Reclaim disk from merged/closed worktrees
│   └── board-digest.sh            Deterministic board-state report (no LLM)
├── ledger.md, logs/, state/      Machine-local runtime state (gitignored)
└── diagrams/                     Supporting diagrams
```

## More information

- **[design.md](design.md)** — the full design: core principles, the actor model, the
  dispatch loop, checker verdict routing, the safety model, state & durability, and
  build history. Read this before changing dispatch logic or the safety model.
- **[CLAUDE.md](CLAUDE.md)** — conventions and gotchas for Claude Code sessions
  working in this repo.
- `briefs/*-brief.md` — the exact protocol each role (worker/checker/orchestrator) is given.

## License

[MIT](LICENSE) © Emmett Reynier
