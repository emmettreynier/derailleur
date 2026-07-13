---
name: write-issue
description: EXPLICIT-INVOCATION ONLY — invoke only when the user runs `/write-issue` or explicitly asks to write/author/define a GitHub issue. Do NOT trigger automatically or proactively. Interview-driven authoring of a well-specified issue for the derailleur autonomous-worker loop: grills the user one question at a time until the issue has a clear goal, context, machine-checkable acceptance criteria, defined outputs, and validation checks — then offers to create it (or edit an existing under-specified one) via `gh`.
---

# write-issue

Interview the person opening a GitHub issue until the issue is well-specified enough
to hand to an autonomous worker, then create it. This is `/grill-me` pointed at issue
authoring: relentless, one question at a time, always with a recommended answer.

**Do not invoke this skill on your own.** It runs only when the user types
`/write-issue` or explicitly asks to write/author/define an issue.

## Why the bar is high (the execution model this feeds)

In derailleur, the issue you author is executed by a **headless Claude Code worker
with no session memory and no human approving its tool calls**, and then verified by
an **LLM checker that re-runs the outputs against the acceptance criteria**. There is
no one to ask a clarifying question mid-run. So vagueness a human collaborator would
paper over instead causes one of: a bounce to `needs-definition` (wasted round-trip),
burned worker budget on the wrong thing, or a PR the checker cannot verify.

Hold every answer to this bar: **could a stranger with repo access, given only this
issue, produce the right deliverable — and could a checker mechanically confirm they
did?** The orchestrator's intake gate demands a real contract: **goal + acceptance
criteria + defined outputs.** If the draft wouldn't pass that gate, keep grilling.

## Method

1. **Scan first, ask second** (grill-me's "explore instead of ask"):
   - Detect the target repo from the current directory via `gh` (e.g.
     `gh repo view --json nameWithOwner -q .nameWithOwner`). Echo it — never assume it
     silently.
   - `gh issue list` (open + recently closed) to catch a **duplicate or overlapping**
     issue *before* investing in a draft. Surface any match and ask whether to proceed,
     extend the existing one, or stop.
   - Grep/read the tree for the files, scripts, and data paths the task touches, so
     Context / criteria / validation reference things that **actually exist** ("cluster
     SEs by county in `analysis/03-wage-reg.R`, table to `out/tables/`"), not vague
     gestures ("add a robustness check").

2. **Refining an existing issue.** If invoked with an issue number or URL, read the
   current body plus any `needs-definition` / checker / reviewer comments, and grill
   only the **gaps** — don't re-litigate what's already solid. This is the "define a
   bounced issue" inbox flow.

3. **Interview relentlessly, one question at a time.** Walk the decision tree, resolving
   dependencies as you go. For **every** question give your recommended answer so the
   user can accept in a word. Grill hardest on the three things that actually break the
   autonomous loop:
   - the **why** behind the goal (is this the right problem, framed the right way?);
   - making every **acceptance criterion machine-checkable** (not "improve X" but "X
     satisfies test/threshold Y");
   - the **concrete output** — exact form *and* path.

4. **Right-size it.** Target **one issue → one PR → one checker pass**. If the goal
   bundles independent deliverables or can't be verified in a single checker pass,
   propose splitting into separate linked issues (note any dependency order). The user
   can override and keep it as one.

5. **Keep going until the user says stop.** There is no auto-terminus — this is fully
   relentless. But **before assembling the draft**, self-audit against the intake gate
   and explicitly warn if it would still bounce as `needs-definition`.

## The issue structure to assemble

Fill exactly these five sections. Use `- [ ]` checkboxes for acceptance criteria.
Goal and Expected outputs map 1:1 to the "Goal" and "Key outputs" sections of the PR
results-summary the worker will fill in, so phrase them so the answer can be pasted
back at review time.

```markdown
## Goal
<One sentence: what will be true when this is done, and why it matters.>

## Context
<Everything a memory-less worker needs: current state, the relevant files / scripts /
data paths, constraints (e.g. never touch raw inputs), prior work, and why now.>

## Acceptance criteria
- [ ] <Concrete, checkable statement.>
- [ ] <Each one independently verifiable by the checker.>

## Expected outputs
<The deliverable's exact form AND path — regression table at `out/tables/x.tex`,
cleaned parquet + a summary of row/col counts, a robustness grid, an annotated
bibliography, etc. Form depends on the task type; be specific.>

## Validation checks
<The exact commands / inspections that PROVE each criterion — what the worker should
run to self-check and what the checker will re-run. e.g. `Rscript analysis/03-wage-reg.R`
then confirm the county-clustered SEs appear in the output table.>
```

## Finish: create or edit via gh

1. Show the fully assembled markdown draft and get an explicit **yes** before touching
   GitHub. Never create/edit silently.
2. **New issue:** confirm the detected `owner/repo`, then create:
   ```bash
   gh issue create -R <owner/repo> --title "<title>" --body "<body>"
   ```
   Offer to add `--label hold` — the orchestrator hard-excludes `hold`, so use it to
   park an issue you're still refining so it won't be dispatched before you're ready.
3. **Existing issue:** `gh issue edit <#> -R <owner/repo> --body "<body>"`; if it carried
   `needs-definition`, offer to remove that label so it re-enters the dispatch pool.
4. Report the created/edited issue URL.
