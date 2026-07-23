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

Why "derailleur"? Well, mostly just because I like bikes. Maybe there is some deep metaphor
related to the shifting mechanism which allows a cyclist to ride at similar effort 
levels across many different speeds 🤷🚲 

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
   in-repo host hooks are executable, creates `logs/` + `state/`, scaffolds
   `orchestrator.conf` from `orchestrator.conf.example`, renders the opt-in
   `/orchestrate` slash command into `~/.claude/commands/` (the one, narrow
   `~/.claude/` carve-out — see below), and symlinks the `derailleur`/`dr` CLI
   into `~/.local/bin` (see *The `derailleur` / `dr` command* below). Idempotent.
5. Fill in `orchestrator.conf` with your identity (`OPERATOR_NAME`, `GITHUB_HANDLE`,
   `PR_OWNER`, `LAUNCHD_LABEL`, `BOARD_PROJECT`) — it's gitignored and per-operator. Every field is required; the
   scripts abort with guidance if any is blank. See `orchestrator.conf.example` for more information.
6. Verify: `claude --version`, then a dry run: `./bin/launch-orchestrator.sh --dry-run`.

This registers **no hooks and no default behavior** in `~/.claude/` — the worker/checker
safety hooks are passed to each dispatch by in-repo path, so your normal interactive
Claude Code sessions elsewhere on the machine stay untouched. The single, narrow
exception is the `/orchestrate` slash command file (`~/.claude/commands/orchestrate.md`),
which is inert until you type it: it registers no hook and changes no default session
behavior. Its rendered copy bakes in this checkout's absolute path, so **re-run
`./bin/install.sh` if you move the repo** — otherwise `/orchestrate` points at the old
location until you do. See `design.md` → *Portability & bootstrap* for the full split
between what's portable (this repo + GitHub) and what's machine-local.

Because that rendered file bakes in an absolute path, **`~/.claude/commands` must not be
a versioned directory.** Some dotfiles setups symlink it into a git repo; if yours does,
`install.sh` resolves the render target through symlinks and warns when it lands inside a
work tree — heed it, because a committed `orchestrate.md` carries one machine's home
directory and breaks `/orchestrate` on every other machine that pulls it. Either gitignore
the file there or repoint `~/.claude/commands` somewhere unversioned.

### Verify / smoke test

`./bin/smoke-test.sh` is a one-command check that the operator-identity bootstrap
still works. All dispatch flows through a single guard in `bin/config-common.sh`,
which reads your gitignored `orchestrator.conf` and aborts if it's missing or any of
the five fields (`OPERATOR_NAME`, `GITHUB_HANDLE`, `PR_OWNER`, `LAUNCHD_LABEL`,
`BOARD_PROJECT`) is blank. The smoke test exercises that guard end-to-end so a
regression is caught here, not on a labmate's first real run.

**What it checks** (against throwaway temp confs — it never touches your real one):
a missing conf aborts; a conf with a blank field aborts *and names the field*; a
fully-filled conf exits 0, exports all five vars, and renders `{{OPERATOR_NAME}}`
into a brief the way the launchers do. It also exercises the `derailleur`/`dr` CLI
dispatcher — `help`/unknown-command/sourced-lib routing, and (the subtle part)
that it resolves back to this checkout when invoked through a symlink, the way
`install.sh` links it onto PATH. If a real `orchestrator.conf` is present it
also confirms *your* conf passes the guard, and — when `gh` is authenticated —
that `launch-orchestrator.sh --dry-run` renders your board digest. It asserts your
real conf is byte-identical before and after.

**When to run it:** right after `./bin/install.sh` and filling in
`orchestrator.conf`, and any time you edit `orchestrator.conf`, the launchers, or
`bin/config-common.sh`.

**How to run it:**

```bash
./bin/smoke-test.sh            # prints PASS / SKIP per check; exits 0 if all pass
```

**How to read a failure:** each check prints a `PASS:` line; steps that need the
network or `gh` auth print `SKIP:` and never fail the run (it's deterministic and
passes offline). On the first failed check the script prints a `FAIL:` line saying
*what failed + what to do*, points back to this section, and exits nonzero.

### Onboard a project

1. Choose an **archetype**: `git-native` (preferred — repo is git-only, data is a
   symlink) or `dropbox-native` (coauthored/legacy — repo lives in Dropbox).
2. `./bin/new-project.sh <owner/repo> [--archetype …] [--clone …] [--worktrees …]` —
   creates the label set, ensures an out-of-Dropbox working clone + worktrees dir,
   and scaffolds `projects/<repo>.yml`. Idempotent.
3. Fill the scaffolded manifest's TODOs — board `project`, `raw_resolved`, and
   confirm `data_root`/paths. **Code-only repo (no data tree)?** Point both
   `data_root` and `raw_resolved` at the repo root itself (same as `working_clone`)
   and leave `raw_paths`/`output_paths` empty — the launcher then skips the `data/`
   scaffold (see `templates/project.yml` for why).
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

By default it runs night-heavy (roughly 8pm/11pm/2am/5am/8am on weeknights, jittered)
so it spends your Claude usage while you're asleep instead of competing with you during
the day. See `design.md` → *Scheduling & power* for the full mechanics (usage-limit
backoff, `pmset` wake chain, concurrency cap).

**Changing the cadence** is a single-line edit. The schedule lives in exactly one
place — `SCHEDULE_SLOTS` in `orchestrator.conf` (space-separated 24h `HH:MM` slots) —
and `install` derives both the `launchd` fire times and the `pmset` wake chain from it,
so the two can never desync:

```bash
# in orchestrator.conf:  SCHEDULE_SLOTS="00:00 01:00 02:00 ... 23:00"   # e.g. hourly
./bin/schedule.sh install       # re-render the plist + re-seed the wake chain from it
./bin/schedule.sh status        # confirm the slots now in effect
```

Unset, it falls back to the night-heavy default; a malformed slot (not `HH:MM`) fails
loud at `install` rather than producing a broken plist.

## Usage

### The `derailleur` / `dr` command

`install.sh` symlinks a small dispatcher onto your PATH so every `./bin/<script>.sh`
below can be run from **any** directory as `derailleur <command>` — or the short
`dr <command>`. It forwards all arguments through unchanged, so every flag documented
here works identically:

```bash
dr launch-worker solar-income 1 --dry-run    # == ./bin/launch-worker.sh solar-income 1 --dry-run
dr orchestrator-cycle --dry-run
dr worktree-prune --auto
dr help                                        # list every available command
```

The examples below show the `./bin/<script>.sh` form (which always works from the repo
root); read `dr <command>` as the equivalent shortcut from anywhere. Two caveats: the
symlink lives in `~/.local/bin`, which must be on your PATH (install warns, with the
exact `~/.zshrc` line, if it isn't); and because the symlink points back into this
checkout, **re-run `./bin/install.sh` if you move the repo** — same as `/orchestrate`.

### Interactive orchestrator (human-gated)

Turn any interactive `claude` session — in **any** repo — into an orchestrator that
loads board state and proposes what to dispatch, acting only on your explicit OK:

```bash
/orchestrate            # whole board: propose worker + checker dispatches, wait for your "go"
/orchestrate solar-income   # scope the view to one onboarded repo
```

Rendered into `~/.claude/commands/` by `install.sh` (the one `~/.claude/` carve-out).
It **proposes, then dispatches workers and checkers only after you confirm** — never
autonomously, and it never merges. Its tools are scoped to the board digest, the two
launchers, read-only `gh`, and the `Monitor` tool (so it can watch the workers/checkers
it dispatched to completion without blocking your session). For a session booted from
this checkout with the digest pre-injected (same posture), use
`./bin/launch-orchestrator.sh` instead.

### Run one orchestration pass by hand

```bash
./bin/orchestrator-cycle.sh              # real pass: prune -> dispatch checkers -> dispatch workers
./bin/orchestrator-cycle.sh --dry-run    # plan only — nothing dispatched, nothing spent
```

Tunable by env var, e.g. `WORKER_BUDGET=6 ./bin/orchestrator-cycle.sh`:

| Var | Default | What it does |
|---|---|---|
| `CAP` | `2` | Max workers in flight at once (tied to your review bandwidth, not CPU). |
| `BUDGET` | `2.00` | Orchestrator session budget (USD). |
| `MODEL` | `sonnet` | Orchestrator session model. It only reads the digest and routes, so it's pinned cheap — and pinned at all, so a cycle never inherits whatever expensive model your interactive sessions default to. |
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
./bin/schedule.sh plan-only     # back to no-spend (mechanically: cycles cannot dispatch for real)
./bin/schedule.sh run           # run one cycle right now (respects the current mode)
./bin/schedule.sh run --dry-run # run one cycle right now in plan-only mode (free)
./bin/schedule.sh pause         # stop firing entirely (e.g. while away); refuses if a worker is in-flight
./bin/schedule.sh pause --force # pause even with live workers (bootout SIGTERMs them — loses their work)
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
│   ├── orchestrator-brief.md            Autonomous (Phase 4) dispatch brain
│   └── orchestrator-interactive-brief.md  Human-gated brain, shared by launch-orchestrator + /orchestrate
├── templates/
│   ├── project.yml                  Tracked, sanitized manifest shape (new-project.sh renders it)
│   ├── orchestrate.command.md          /orchestrate source (install renders it to ~/.claude/commands/)
│   └── pr-results-summary.md        The results-summary PR template workers fill in
├── host/hooks/                   PreToolUse / Stop / SessionStart hooks (the safety layer)
├── host/LaunchAgents/            launchd plist template for the scheduled loop
├── bin/                          All shell entrypoints (invoke as ./bin/<script>.sh, or via the `dr` CLI)
│   ├── derailleur                CLI dispatcher: `derailleur`/`dr <cmd>` -> bin/<cmd>.sh (linked onto PATH by install)
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
│   ├── board-digest.sh            Deterministic board-state report (no LLM)
│   └── watch-dispatch.sh          Watch dispatched worker(s)/checker(s) to terminal state (local signals; no LLM)
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
