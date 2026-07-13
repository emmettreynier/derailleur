<!--
Results-summary PR template (orchestrator). Every worker fills this so the PR can be
reviewed as a research advisor — evaluating outputs and asking probing questions —
without reading the diff. The checker verifies each section exists and the outputs are real.
Copy to a repo's .github/pull_request_template.md, or have the worker emit it as the PR body.
-->

## Goal

<!-- What the issue asked for, one line. -->
Closes #

## What I did

<!-- 2–3 sentences. -->

## What I ran

<!-- Exact script/command(s) — reproducible. -->

```
```

## Key outputs

<!-- The actual table / figure / numbers, SHOWN here (paste values or embed the plot).
     Not "see code." Form depends on the task: cleaned-data summary, regression table,
     robustness grid, annotated bibliography, etc. — as defined in the issue. -->

## Judgment calls / open questions

<!-- Assumptions made, and anything you'd want probed. -->

## Standing guards

<!-- Attest to each self-check (held on every PR, regardless of the issue). -->
- Secrets / absolute paths / PII: none in diff.
- Changed entry point runs clean from a fresh session: <command + result>.
- Seeds: <set where sampling/simulation/bootstrap introduced, or "n/a — none introduced">.
- Docs: <updated: files> OR <no docs needed: reason>.

## Outcome

<!-- Typed self-report: pick one.
     - shipped     — a change here satisfies the issue.
     - no-op       — already satisfied / duplicate; nothing to change (say why).
     - blocked     — couldn't finish; paired with a needs-input question.
     - handed-off  — ran out of budget; WIP pushed, /handoff state comment left. -->
shipped
