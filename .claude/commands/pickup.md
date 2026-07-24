---
description: Resume work on an issue — read the issue, last state comment, and PR diff, then continue from where the last session paused
argument-hint: "<issue number or branch name>"
allowed-tools: Bash(git status:*), Bash(git fetch:*), Bash(git checkout:*), Bash(git switch:*), Bash(git pull:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(gh pr:*), Bash(gh issue:*), Bash(gh project:*), Bash(rtk git status:*), Bash(rtk git fetch:*), Bash(rtk git checkout:*), Bash(rtk git switch:*), Bash(rtk git pull:*), Bash(rtk git branch:*), Bash(rtk git log:*), Bash(rtk git diff:*), Bash(rtk gh pr:*), Bash(rtk gh issue:*), Bash(rtk gh project:*)
---

Resume work that a previous session left off. GitHub is the source of truth — reconstruct state from it, don't guess. Treat $ARGUMENTS as the issue number or branch name (ask me if it's missing or ambiguous).

Do the following, then **stop and summarize before making any code changes** so I can confirm the plan:

1. **Read intent.** `gh issue view <n>` (with `--comments`) to read the issue body, acceptance criteria, and especially the **most recent state comment** — that's the handoff note describing done / remaining / next step.

2. **Get on the branch.** Find the branch/PR for this issue (`gh pr list --search <n>` or the branch named in the state comment). `git fetch`, then check it out and pull so you have the latest pushed work. If no branch exists yet, note that this is a fresh start.

3. **Mark it active.** If this work is tracked on a project board, set the issue's status to **In Progress** (add it to the board first if it's not on one). Board specifics — which project, how to find the item, field details — come from your CLAUDE.md; skip this step if you don't use a board.

4. **Review work so far.** Look at the PR description and `git log`/`git diff` against the base branch to see what's actually been done. Reconcile this with the issue's acceptance criteria — what's checked off, what remains.

5. **Confirm the plan.** Summarize for me:
   - **Where it stands:** branch, PR URL, what's complete
   - **Next step:** the concrete action from the state comment (or your best read if absent)
   - **Open questions:** anything ambiguous or any conflict between the comment and the actual diff

Then wait for my go-ahead before continuing the work. When I'm ready to pause again, I'll use `/handoff`.
