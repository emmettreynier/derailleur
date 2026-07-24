---
description: Daily driver — read the board + today's sprint log, reconcile stale statuses, then either suggest a focus (and stub the day's plan) or log what you did (and propose issue closes)
argument-hint: "[time/energy available, or a description of what you did]"
allowed-tools: Bash(gh issue:*), Bash(gh project:*), Bash(git log:*), Bash(rtk gh issue:*), Bash(rtk gh project:*), Bash(rtk git log:*), Read, Edit, Write, Glob, Grep
---

The daily touchpoint over the hub board and the current sprint log. Same command morning and evening — it reads the same state either way and branches on what you give it. GitHub is the source of truth for tasks; the sprint `log.md` is the narrative GitHub can't hold. Board specifics (project #3 "Research Board", Status/Project/Sprint fields, option IDs) come from your CLAUDE.md — read the board with `gh project item-list 3 --owner @me --format json -L 500` and get field/option IDs from `gh project field-list 3 --owner @me --format json`.

This command **plans and records** — it never touches git branches or PRs. Paused project-repo code work is `/handoff`'s job; if the user's report describes that, point them there rather than doing it.

## Always do first (both modes)

1. **Find the current sprint.** The newest `sprints/sprint-YYYY-MM-DD/` folder; read its `log.md`. If there's no active sprint (the latest is well past its 2-week window), say so and suggest `/sprint` — don't invent a log.
2. **Read the board.** Pull items in the current sprint (Sprint field = the folder's date) plus anything `In Progress` or `Blocked`, cross-repo. Match items by `.content.url`, never by issue number (numbers collide across repos).
3. **Surface deadlines** landing within ~2 weeks — board `Deadline` field plus `deadlines.md`.
4. **Reconcile stale statuses — propose, don't auto-write.** If the log shows recent work on an issue whose board status lags (e.g. still `Up Next` but worked this week), or something `In Progress` looks stalled, propose the fix ("bump #N to In Progress? [y]") and only edit the board on confirmation. Never move an item silently. **Done is automatic on close/merge — never set it by hand.**

## Then branch on `$ARGUMENTS` (or what the user says)

### Reporting work → log it + propose closes
If the input describes what got done:
1. **Append under today's heading.** Find or create the single `## YYYY-MM-DD` section in `log.md` (today's date). If `/checkin` already stubbed a plan there this morning, append the actuals under it — never create a duplicate date. Keep entries terse, in the log's existing bullet style.
2. **Propose issue bookkeeping — confirm before writing.** Map the prose to board issues and propose, one at a time:
   - **Finished** → close with a brief outcome comment. Show the draft `gh issue close -c "..."` comment and wait for the go-ahead; the board moves it to `Done` automatically.
   - **Partial** → check off completed acceptance criteria or leave a short progress comment.
   Never close or comment on an issue without showing the exact text first.
3. **Point to `/handoff`** if the work is paused code work in a project repo (uncommitted changes, an open branch/PR) — that needs a branch/push/PR/state-comment, which is out of scope here.

### Planning the day / "what should I work on" → suggest a focus + stub the plan
If the input is empty, or asks what to work on:
1. **Learn the constraint.** If `$ARGUMENTS` didn't give time/energy, ask before recommending ("how much time and energy today?").
2. **Recommend a focus**, not a menu: given the sprint commitments, what's `In Progress`, near deadlines, and the stated time/energy, name the one or two things to move today and why. Honor the "group by project" principle — cluster around one domain rather than scattering.
3. **Stub the plan into the log.** Write today's `## YYYY-MM-DD` heading (if absent) with the agreed focus as bullets, so the evening `/checkin` fills in actuals under it.

Finish with a one-line summary of what you changed (board edits, log lines) and, in planning mode, the recommended focus.
