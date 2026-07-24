---
description: Leave the repo recoverable — commit, push, update the PR (draft if WIP, ready if complete), and post a state comment on the issue
argument-hint: "[optional note about where things stand]"
allowed-tools: Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(gh pr:*), Bash(gh issue:*), Bash(gh project:*), Bash(rtk git status:*), Bash(rtk git add:*), Bash(rtk git commit:*), Bash(rtk git push:*), Bash(rtk git branch:*), Bash(rtk git log:*), Bash(rtk git diff:*), Bash(rtk gh pr:*), Bash(rtk gh issue:*), Bash(rtk gh project:*)
---

Wrap up the current session so any agent (or I) can pick this work up cleanly from GitHub alone. GitHub is the source of truth — leave nothing critical stuck in session context.

Do the following, reporting what you did at each step. Skip a step only if it genuinely doesn't apply, and say so.

1. **Orient.** Run `git status` and `git branch --show-current`. If on the default branch (`main`/`master`) with real changes, create a topic branch first.

2. **Commit.** Stage and commit all meaningful uncommitted work with a clear message describing *what changed and why*. WIP commits are fine — note "WIP" in the message if incomplete. Do not commit secrets, large data files, or generated artifacts.

3. **Push.** Push the branch to the remote so the work is durable.

4. **PR.** Check for an existing PR for this branch (`gh pr view`). If none, open one linked to the issue with `Closes #<n>` in the body (ask me for the issue number if you can't infer it). Update the PR description to be an accurate running summary of the work.
   - **WIP / paused:** keep it a **draft**.
   - **Complete** (the work meets the issue's acceptance criteria): before marking the PR **ready**, run a quick self-check against your repo's conventions — docs updated (or explicitly not needed)? no secrets or absolute local paths in the diff? the changed piece actually runs? Then `gh pr ready`, which hands it off for review. If unsure whether it's done, leave it draft and say so.

5. **State comment.** Post a comment on the linked issue (`gh issue comment`) capturing the handoff state:
   - **Done:** what's complete
   - **Remaining:** what's left, ideally as `- [ ]` items
   - **Next step:** the single concrete next action
   - **Notes:** anything tried that didn't work, or decisions made

6. **Board status.** If this work is tracked on a project board: when it's paused but unfinished, leave the status as **In Progress**; if it's stuck on something external, set it to **Blocked** and say what it's waiting on in the state comment. (When you marked the PR ready in step 4, don't touch the status — completion moves it automatically on merge.) Board specifics come from your CLAUDE.md; skip if you don't use a board.

If I passed a note in $ARGUMENTS, fold it into the state comment.

Finish with a one-line summary of the branch, PR URL, and issue so I have the links.
