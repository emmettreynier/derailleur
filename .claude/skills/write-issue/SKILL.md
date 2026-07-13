---
name: write-issue
description: EXPLICIT-INVOCATION ONLY — invoke only when the user runs `/write-issue` or explicitly asks to write/author/define a GitHub issue. Do NOT trigger automatically or proactively. Interview-driven authoring of a well-specified GitHub issue: grills the user one question at a time until the issue has a clear goal, context, machine-checkable acceptance criteria, defined outputs, and validation checks — then offers to create it (or edit an existing under-specified one) via `gh`.
---

# write-issue

Interview the person opening a GitHub issue until the issue is well-specified enough
that whoever picks it up can execute it correctly without asking a follow-up, then
create it. This is `/grill-me` pointed at issue authoring: relentless, one question at
a time, always with a recommended answer.

## Why the bar is high

The issue may be executed by someone — or an agent — with **no memory of this
conversation and no chance to ask you a clarifying question mid-run**: a headless
autonomous worker, or simply a fresh interactive session weeks from now. Either way,
success also has to be **verifiable** from the issue alone — someone, or an automated
check, re-runs the outputs against the acceptance criteria. So vagueness a human
collaborator would paper over instead causes one of: a wasted round-trip back to you
for definition, effort burned on the wrong thing, or a result no one can confirm.

Hold every answer to this bar: **could a stranger with repo access, given only this
issue, produce the right deliverable — and could a reviewer mechanically confirm they
did?** A real contract needs **goal + acceptance criteria + defined outputs**; if the
draft lacks any of those, keep grilling.

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
   current body plus any prior review / verification comments, and grill only the
   **gaps** — don't re-litigate what's already solid. This is the refine-an-
   underspecified-issue flow.

3. **Interview relentlessly, one question at a time.** Walk the decision tree, resolving
   dependencies as you go. For **every** question give your recommended answer so the
   user can accept in a word. Grill hardest on the three things that most often derail
   execution:
   - the **why** behind the goal (is this the right problem, framed the right way?);
   - making every **acceptance criterion machine-checkable** (not "improve X" but "X
     satisfies test/threshold Y");
   - the **concrete output** — exact form *and* path.

4. **Right-size it.** Target **one issue → one PR → one verification pass**. If the goal
   bundles independent deliverables or can't be verified in a single pass, propose
   splitting into separate linked issues (note any dependency order). The user can
   override and keep it as one.

5. **Apply the standing criteria** (see below). Before assembling the draft, walk the
   standing-criteria list and decide which apply to *this* change. The four integrity
   guards apply to essentially every code-touching issue; the three hygiene checks are
   conditional. Fold the applicable ones into Acceptance criteria / Validation checks so
   they read as issue-specific, not boilerplate stapled on at the end.

6. **Keep going until the user says stop.** There is no auto-terminus — this is fully
   relentless. But **before assembling the draft**, self-audit against the bar above and
   explicitly warn if it's still underspecified (missing goal, machine-checkable
   criteria, or defined outputs).

## The issue structure to assemble

Fill exactly these five sections. Use `- [ ]` checkboxes for acceptance criteria.
Goal and Expected outputs map 1:1 to the "Goal" and "Key outputs" sections of the PR
results-summary that gets filled in when the work is done, so phrase them so the answer
can be pasted back at review time.

```markdown
## Goal
<One sentence: what will be true when this is done, and why it matters.>

## Context
<Everything a memory-less executor needs: current state, the relevant files / scripts /
data paths, constraints (e.g. never touch raw inputs), prior work, and why now.>

## Acceptance criteria
- [ ] <Concrete, checkable statement.>
- [ ] <Each one independently verifiable.>

## Expected outputs
<The deliverable's exact form AND path — regression table at `out/tables/x.tex`,
cleaned parquet + a summary of row/col counts, a robustness grid, an annotated
bibliography, etc. Form depends on the task type; be specific.>

## Validation checks
<The exact commands / inspections that PROVE each criterion — what the executor runs to
self-check and what a reviewer re-runs. e.g. `Rscript analysis/03-wage-reg.R`
then confirm the county-clustered SEs appear in the output table.>
```

## Standing criteria

Checks the interview **always considers** — so the memory-less executor gets them even
when the user forgets to mention them. Don't paste all seven in blindly: probe each
against the actual change, and only add the ones that bite. Phrase each as a
machine-checkable acceptance criterion (with a matching validation check).

**Integrity guards (apply to essentially every code-touching issue):**

1. **Raw/source data is untouched.** Raw inputs are read-only; writes go only to
   derived/output dirs. *Check:* no diff under the raw-data path. (Highest-value guard —
   especially for the sensitive health datasets.)
2. **No secrets, credentials, absolute local paths (`/Users/...`), or PII in the diff.**
   *Check:* grep the diff for those patterns.
3. **The changed piece runs clean.** Only the script/function/stage being changed
   executes end-to-end without error from a fresh session — **not** the whole pipeline.
   Name the exact entry point in Validation checks (e.g. `Rscript analysis/03-wage-reg.R`),
   and if that stage depends on upstream outputs, say they're assumed already built.
4. **Determinism — seeds set** wherever there's sampling / simulation / bootstrap, so
   results reproduce. *Check:* `set.seed(...)` present in any stochastic step.

**Hygiene (conditional — add when the change touches them):**

5. **Documentation currency.** Docs reflecting the change are updated — README,
   CLAUDE.md, and any other affected docs — **or** the PR states explicitly that no
   user-facing docs needed updating, with a one-line reason. *Check:* a doc diff or an
   explicit "no docs needed" note.
6. **Dependencies declared and pinned.** Any new package is recorded in the repo's
   environment manifest for that language, and both the language version and package
   versions are pinned so it reproduces elsewhere — e.g. R (`renv.lock` / DESCRIPTION,
   plus the R version), Julia (`Project.toml` + `Manifest.toml`, plus the `julia`
   compat/version), Python (`pyproject.toml` / `requirements.txt` + a lockfile, plus the
   Python version). *Check:* every newly imported/loaded package appears in the manifest,
   and the manifest/lockfile is committed.
7. **Repo conventions followed** — defers to the repo's CLAUDE.md. Point at CLAUDE.md as authority
   rather than restating the rules.

## Finish: create or edit via gh

1. Show the fully assembled markdown draft and get an explicit **yes** before touching
   GitHub. Never create/edit silently.
2. **New issue:** confirm the detected `owner/repo`, then create:
   ```bash
   gh issue create -R <owner/repo> --title "<title>" --body "<body>"
   ```
   If an automated pickup loop runs against the repo, offer to add `--label hold` to
   park an issue you're still refining so it won't be picked up before you're ready.
3. **Existing issue:** `gh issue edit <#> -R <owner/repo> --body "<body>"`; if it carried
   a label marking it underspecified (e.g. `needs-definition`), offer to remove that
   label now that the gaps are filled.
4. Report the created/edited issue URL.
