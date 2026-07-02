# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Derailleur is a local, autonomous system that dispatches GitHub-issue work to headless
Claude Code workers, verifies it with an LLM checker, and surfaces only the decisions
that need Emmett. It is pure bash + python glue around `gh`/`jq` and the `claude` CLI —
there is no application code, build step, package manager, or test suite.

**Read [README.md](README.md) first** for what the system does, install/onboarding
steps, and common commands. **Read [design.md](design.md)** before touching the
dispatch loop, checker routing, or the safety model — it's the full design record
(core principles, actor model, label vocabulary, safety layers, state & durability)
and this file does not repeat it.

## Conventions and gotchas specific to working on this codebase

- All shell scripts live in `bin/`; role briefs live in `briefs/`. Every script
  resolves the **repo root**, not its own directory, as `ORCH`/`ORCH_DIR`
  (`cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd`) — keep that `/..` when adding a
  script to `bin/`, and reference sibling scripts/briefs as `$ORCH/bin/...` /
  `$ORCH/briefs/...` (everything else — `projects/`, `templates/`, `host/`,
  `ledger.md`, `logs/`, `state/` — stays directly under `$ORCH`).
- Scripts use `set -euo pipefail`. macOS ships bash 3.2: expanding an **empty array**
  under `set -u` (e.g. `"${flag[@]}"` with no `--force`) is a fatal `unbound
  variable` error — branch on the flag instead of building-then-expanding an
  optional-arg array (see `bin/worktree-prune.sh` history for the bug this caused).
- `bin/dispatch-common.sh` is sourced, not executed, by both launchers — shared
  post-run logic (interruption classification, pushing stranded commits, the
  new-session `setsid` shim for detached dispatch) belongs there, not duplicated.
- `briefs/*-brief.md` files are the protocol layer, rendered by their launcher with
  `{{TOKEN}}` substitution — edit them for lifecycle/signal changes, keep the
  tokens intact if you edit the surrounding prose.
- Prefer a script's `--dry-run` flag over editing blind when verifying a change —
  there's no test suite, so `--dry-run` output and `logs/cycle.log` are how you
  check correctness.
- Check `design.md`'s "Verified CLI capabilities" table before relying on a
  `claude` CLI flag — some (e.g. `--max-turns`) don't exist in the pinned version.
- Any change to the safety model (hooks in `host/hooks/`, `--add-dir`,
  `--disallowedTools`, budgets) is high-blast-radius: workers run unattended with
  no human approving tool calls, so a regression fails silently until something
  destructive happens.
