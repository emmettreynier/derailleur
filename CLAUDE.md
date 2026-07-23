# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Start here

The README is imported below, so you already have what the system does, install/onboarding
steps, and common commands — no need to open it separately.

@README.md

**[design.md](design.md) is the most important document for changing behavior — read it**
before touching the dispatch loop, checker routing, or the safety model. It's the full
design record (core principles, actor model, label vocabulary, safety layers, state &
durability); this file does not repeat it, and it is *not* auto-loaded, so read it on demand.

## Conventions and gotchas specific to working on this codebase

- All shell scripts live in `bin/`; role briefs live in `briefs/`. Every script
  resolves the **repo root**, not its own directory, as `ORCH`/`ORCH_DIR`
  (`cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd`) — keep that `/..` when adding a
  script to `bin/`, and reference sibling scripts/briefs as `$ORCH/bin/...` /
  `$ORCH/briefs/...` (everything else — `projects/`, `templates/`, `host/`,
  `ledger.md`, `logs/`, `state/` — stays directly under `$ORCH`).
- `bin/derailleur` is the one **extensionless** script (the user-facing CLI name,
  like `git`), so it's deliberately outside the `bin/*.sh` glob that `install.sh`
  uses for chmod and that the dispatcher's own `help` uses to list commands — it
  never lists or dispatches to itself. It is invoked via a symlink from
  `~/.local/bin` (created by `install.sh`), so it can't use the plain
  `dirname/..` root resolution the other scripts use: it walks the symlink chain
  first (portable loop, no `readlink -f` — macOS bash 3.2 lacks it), then takes
  `bin/..`. It bakes in **no path**; moving the repo needs a re-run of
  `install.sh` to refresh the symlink (same caveat as `/orchestrate`).
- Scripts use `set -euo pipefail`. macOS ships bash 3.2: expanding an **empty array**
  under `set -u` (e.g. `"${flag[@]}"` with no `--force`) is a fatal `unbound
  variable` error — branch on the flag instead of building-then-expanding an
  optional-arg array (see `bin/worktree-prune.sh` history for the bug this caused).
- Same `set -e` family: a shell function must not **end** on a bare short-circuit
  (`[ cond ] && x=1`) — when the test is false the function returns nonzero, and a
  caller that invokes it bare (not in an `if`/`&&`) aborts the whole script with no
  output. End such helpers with an explicit `return 0` (this silently killed
  `worktree-prune.sh --auto`, issue #23).
- `bin/dispatch-common.sh` is sourced, not executed, by both launchers — shared
  post-run logic (interruption classification, pushing stranded commits, the
  new-session `setsid` shim for detached dispatch) belongs there, not duplicated.
- `briefs/*-brief.md` files are the protocol layer, rendered by their launcher with
  `{{TOKEN}}` substitution — edit them for lifecycle/signal changes, keep the
  tokens intact if you edit the surrounding prose. **Exception:**
  `briefs/orchestrator-interactive-brief.md` is deliberately **token-free** — it's
  shared verbatim by `launch-orchestrator.sh` and the `/orchestrate` command (which
  pulls it in via an `@file` reference that does no substitution), so any operator-
  or path-specific detail must be supplied by the *front* (the launcher appends the
  checkout path; the command body carries the absolute invocations), never baked
  into the brief.
- The `/orchestrate` command source lives in `templates/orchestrate.command.md` with
  a `{{DERAILLEUR_ROOT}}` placeholder; `install.sh` renders it to
  `~/.claude/commands/orchestrate.md`, substituting the path and **stripping the
  leading HTML comment so the YAML frontmatter is the first line** (a command with a
  comment before its frontmatter won't parse). Keep the repo copy path-free — the
  only absolute path appears in the install-rendered output, never in the diff.
- Prefer a script's `--dry-run` flag over editing blind when verifying a change —
  there's no test suite, so `--dry-run` output and `logs/cycle.log` are how you
  check correctness.
- Check `design.md`'s "Verified CLI capabilities" table before relying on a
  `claude` CLI flag — some (e.g. `--max-turns`) don't exist in the pinned version.
- Any change to the safety model (hooks in `host/hooks/`, `--add-dir`,
  `--disallowedTools`, budgets) is high-blast-radius: workers run unattended with
  no human approving tool calls, so a regression fails silently until something
  destructive happens.
