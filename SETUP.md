# Orchestrator — Setup & Onboarding

[Home](README.md) · [Design](design.md)

---

**Status:** skeleton — filled in as the bootstrap scripts land (Phases 1–4). Goal: a new machine or project is reproduced from this repo + GitHub, never from memory. See [design.md](design.md) → *Portability & bootstrap*.

## Portable vs machine-local

| Portable (repo + GitHub) | Machine-local (the bits that "make it tick") |
|---|---|
| design, scripts, templates, briefs, hooks, skills, manifests | `~/.claude/settings.json` (hooks/permissions) |
| labels, board view, branch settings | `~/Library/LaunchAgents/` (`launchd` plist) |
| per-project manifests (`projects/*.yml`) | `~/.claude/skills/`, out-of-Dropbox clones, `gh`/Dropbox auth |

Machine-local *files* are kept canonically in the repo and reproduced on a new machine, so "machine-local" still means "reproducible," split by who owns the wiring:

- **Orchestrator host hooks** (`host/hooks/`) are *not* registered in `~/.claude/`; the launchers pass them per-dispatch by in-repo path (`--settings`/hook flags), so interactive sessions stay untouched. `install.sh` just dep-checks and asserts their executability.
- **The `launchd` plist** is symlinked into `~/Library/LaunchAgents/` by `schedule.sh install`.
- **Your personal `~/.claude/` config** (`CLAUDE.md`, `settings.json`, `hooks/`, `skills/`) is a separate concern owned by `project-management-v2`'s own machine bootstrap (`bootstrap/install.sh`), which symlinks it canonical-in-repo → `~/.claude`. That bootstrap does software deps + `~/.claude` symlinks only — it does not reach into this repo.

## One-time host setup (new machine)

1. Clone this repo.
2. Install deps: `gh`, `jq`, `claude` (Claude Code), Dropbox.
3. `gh auth login`.
4. `./install.sh` — dep-checks (`gh`/`jq`/`claude`/`python3`/`git`), asserts host-hook executability, creates `logs/`+`state/`. Idempotent.
5. Verify: `claude --version`; trigger an orchestrator dry-run.

### Scheduled launcher (Phase 4 — run the loop automatically)

This is the part that runs the orchestrator on a timer instead of you starting it by hand. Once installed, your Mac wakes itself a few times each night, runs one orchestration pass, and goes back to sleep.

**What the words mean** (the rest of this section uses them):

| Term | Plain meaning |
|---|---|
| **a cycle / a pass** | one run of `orchestrator-cycle.sh`: it looks at the board, and may start background workers on ready issues and checkers on open PRs. This is the unit of work the timer fires. |
| **dispatch** | start a background worker or checker. This is the part that actually spends money (uses your Claude usage). |
| **the agent (launchd)** | the macOS timer that fires the cycle on schedule. "Install the agent" = register that timer. |
| **plan-only mode** (`--dry-run`, `ORCH_DRY=1`) | the cycle decides what it *would* do and prints it, but starts nothing and spends nothing. The safe way to test. |
| **go live** | switch from plan-only to actually dispatching — one command (`schedule.sh live`), reversible any time (`schedule.sh plan-only`). |
| **pmset wake** | macOS waking the Mac from sleep at a set time so the timer can fire overnight. |
| **usage gate** | the launcher checking whether you've hit your Claude limit, and skipping the run if so. |

**The schedule:** runs roughly at **8pm, 11pm, 2am, 5am, 8am on weeknights** (each time is randomized by ±15 min so we don't hammer a server at the exact top of the hour along with everyone else's automated jobs). Night-heavy on purpose — it does its spending overnight so it isn't competing with you for your Claude limit during the workday.

#### Step-by-step: turning it on for the first time

Do these in order. Steps 1–2 cost nothing; you only start spending at step 4.

1. **Install the timer in plan-only mode.** It ships safe — the first runs only *plan*, they don't dispatch.
   ```bash
   ./schedule.sh install
   ```
   This symlinks the timer config into `~/Library/LaunchAgents/`, registers it with macOS, and sets up the overnight wakes (it will ask for your password once, for the wake scheduling).

2. **Trigger one run by hand to see it work** (still plan-only, still free):
   ```bash
   ./schedule.sh run --dry-run
   ```
   You'll see it read the board and print what it *would* dispatch. Nothing is started.

3. **Let the scheduled runs happen for a night or two, then check the log.** Confirm the timer actually fired on its own (the most common failure is the timer running but not finding `claude`/`gh` — this proves it does):
   ```bash
   ./schedule.sh status        # is the timer loaded? when's the next wake?
   cat logs/cycle.log          # did it fire overnight, and what did it plan?
   ```
   You're looking for `cycle start` / `cycle end` lines at the scheduled times.

4. **Go live** (this is the switch that lets it spend) — one command, no file editing:
   ```bash
   ./schedule.sh live
   ```
   From now on, scheduled runs dispatch for real. Up to `CAP` (default **2**) workers run at once — that ceiling is set to your *review* bandwidth, not your Mac's. Flip back to no-spend any time with `./schedule.sh plan-only`. (The mode is stored in `state/mode` and read on every run, so the change takes effect on the next scheduled cycle — nothing to reload.)

#### Day-to-day commands

```bash
./schedule.sh status        # timer state, current mode, next wake, usage gate, recent log
./schedule.sh live          # let scheduled runs dispatch for real (spend)
./schedule.sh plan-only     # back to no-spend (runs still happen, just plan)
./schedule.sh run           # run one cycle right now (immediate; respects the current mode)
./schedule.sh run --dry-run # run one cycle right now in plan-only mode (free, regardless of mode)
./schedule.sh pause         # stop firing entirely (e.g. while away) — instant, reversible
./schedule.sh resume        # start firing again after a pause
./schedule.sh uninstall     # remove completely (unregister timer, cancel wakes)
```

**Going on vacation?** Two clean choices:
- *Let it grind while you're gone* — `schedule.sh live` (you're not using your daytime Claude limit anyway; review the pile when you're back).
- *Stop it entirely* — `schedule.sh pause` (instant, sudo-free, keeps your setup; `resume` when home). `plan-only` is **not** the right "off" — a plan-only run still wakes the Mac and spends a few cents booting the planner each night.

#### Two things to know about overnight running

- **Keep the Mac plugged in.** macOS only wakes a Mac from sleep on a timer when it's on AC power. The lid can stay shut — it wakes ~2 min before each scheduled time, runs, and sleeps again. On battery, runs only happen when the Mac is already awake.
- **To get all five nightly wakes, allow `pmset` to run without a password (one-time).** Scheduling a wake needs admin rights, and an unattended overnight run has no way to type your password. Without this, only the *first* nightly wake (~8pm) is guaranteed; the later ones (11pm/2am/5am/8am) silently won't happen. To enable them all, add one line:
  ```bash
  sudo visudo -f /etc/sudoers.d/orchestrator-pmset
  #  then add this line and save:
  #     emmettr ALL=(root) NOPASSWD: /usr/bin/pmset
  ```
  The loop still works without it — just at fewer overnight wakes (plus any time the Mac is already awake).

#### What happens when you hit your Claude limit

These background runs use your normal Claude **subscription**, so they draw from the same usage pool you use during the day. If a run hits your limit, Claude says when it resets (e.g. *"resets 7:40pm"*); the launcher records that and **skips** scheduled runs until then, automatically resuming after. This is why overnight helps — it spends the pool while you're asleep so your daytime window is freer. (It can't create extra quota; it only changes *when* the pool gets used.)

## Onboarding a new project

1. Choose the **archetype**: `git-native` (preferred) or `dropbox-native` (coauthored/legacy).
2. `./orchestrator/new-project.sh <owner/repo> [--archetype …] [--clone …] [--worktrees …]` — creates labels, ensures an out-of-Dropbox working clone + worktrees dir, scaffolds `orchestrator/projects/<repo>.yml`. Idempotent. Defaults: `git-native`; clone `~/projects/<slug>`; worktrees `~/orchestrator/worktrees/<slug>`.
3. Fill the scaffolded `projects/<repo>.yml` TODOs — board `project`, `raw_resolved`, and confirm `data_root`/paths.
4. Add the repo to the board + the "Needs Me" view (manual, GitHub Projects UI).
5. **dropbox-native only:** pin raw data "Available offline" in Dropbox (manual).
6. **Shared repos:** get coauthor buy-in before any `main` branch protection; otherwise rely on the agent deny-hook for "no pushes to `main`."
7. Author one well-specified issue and dry-run a worker by hand.

## Irreducibly manual steps

- GitHub board view membership/filters (Projects UI — not CLI-scriptable).
- Dropbox "Available offline" pinning.
- `gh` / Dropbox authentication.
- Coauthor buy-in for shared-repo branch protection.
