---
name: migrate-repo-out-of-dropbox
description: Use this skill to reorganize a research project so its code lives in a normal git repo outside Dropbox while its large or restricted data stays in Dropbox and is symlinked back into the repo. Trigger whenever the user wants to: move or migrate a git repo out of Dropbox; stop git and Dropbox from fighting over the same folder (Dropbox resyncing .git); separate code from data so code goes in git and the data keeps syncing in Dropbox; restructure into a clean checkout in ~/projects with gitignored data linked from the Dropbox copy; onboard a Dropbox-only project into a fresh code-only clone with raw data linked back in; or fix a dead/stale data symlink that points at a coauthor's or another machine's path. The intent is code-in-git + data-in-Dropbox as separate homes, even if they never say "symlink".
---

# Migrate a repo out of Dropbox

## What this is and why

A research repo often starts life *inside* Dropbox so the data gets backed up
and synced to coauthors. But git + Dropbox in the same directory is a bad mix:
Dropbox constantly re-syncs `.git/` churn, clones can't live in two places, and
an automated worker/orchestrator wants a clean checkout it controls. The fix is
to split the two concerns:

- **Code** lives in a normal git repo *outside* Dropbox (e.g. `~/projects/<name>`).
- **Data** (large, generated, or otherwise gitignored) stays in the Dropbox copy
  and is **symlinked back into the code repo** at the paths the scripts already
  expect.

Because the analysis code uses repo-relative paths (e.g., `cache/`, `data/raw`,
`output/`), the symlinks are transparent: scripts read *and write* straight
through them into Dropbox, so new outputs are still backed up. The code repo
stays small and git-clean; the data stays synced.

The end state is reproducible from a fresh clone with one command
(`./setup-symlinks.sh`), so any machine or worker can rebuild the links.

## The procedure

Work through these phases in order. Confirm the strategy with the user before
you change committed files (untracking placeholders, rewriting `.gitignore`).

### Phase 0 — Orient

1. Read the repo's `README.md` and any `CLAUDE.md` to learn its structure and
   conventions. The data sometimes lives in or is produced by a *separate*
   project (a sibling repo, a shared data folder) — if so, skim that source's
   docs too, since you won't have its context loaded automatically.
2. Pin down the two locations precisely:
   - the **code repo** — the git checkout living outside Dropbox, and
   - the **Dropbox copy / folder** that currently holds the data.
   If you only have one, ask the user for the other. Two common starting points,
   both of which this skill handles:
   - **Existing repo cloned twice** — the same git repo lives both in and out of
     Dropbox; you're reconciling the outside-Dropbox clone against the in-Dropbox
     data.
   - **No git repo yet** — the project is *only* a Dropbox folder and the user
     wants to create the code repo fresh (init or clone it outside Dropbox, leave
     the data behind in the Dropbox folder, symlink it back). Same procedure; the
     only differences land in Phase 4 — you author `.gitignore` from scratch
     rather than reconciling an existing one, and there are no tracked `.gitkeep`
     placeholders to untrack.

### Phase 1 — Discover what needs linking

The goal is a categorized list of every path that holds real data in the Dropbox
copy but is absent (or gitignored) in the code repo. **Every directory name in
this skill is an example** — `cache/`, `data/raw`, `output/`, `dataverse_files/`
are this-project specifics, not a fixed list. Discover the actual structure by
comparing the two trees; don't assume.

```bash
# In the code repo (skip the git lines if the repo doesn't exist yet):
git ls-files | grep -iE 'gitkeep|placeholder'   # tracked placeholders (see Phase 2)
cat .gitignore

# Compare the two trees side by side, then drill into each data-bearing dir to
# see what actually exists in Dropbox vs. the code repo. Adjust paths to fit:
ls -la <code-repo> <dropbox-copy>
ls -la <dropbox-copy>/<data-dir> ...
```

For each gitignored directory/file, note which **category** it falls in — this
drives the granularity decision in Phase 2:

- **Write target** — the pipeline *creates* files here (`cache/`, `data/raw/`,
  `output/`). These must be whole-directory symlinks so newly generated files
  land in Dropbox, not locally.
- **Fully-ignored dir** (no tracked placeholder inside) — e.g. `dataverse_files/`,
  a `data/reynier/`. Clean whole-dir symlink.
- **Dir with a tracked `.gitkeep`** — git keeps the empty dir on a fresh clone via
  the placeholder. See Phase 2 for how this interacts with symlinking.
- **Read-only reference data** — link it; the script's clobber-guard protects it.
- **An already-existing symlink** (a path that is *itself* a symlink in the
  Dropbox copy) — it points at some original source outside this project (a
  sibling project's output, a shared drive). Don't chain a link to the symlink;
  resolve where it really points (`readlink`/`ls -la`) and create a fresh symlink
  to that **original source**, since a symlink-to-a-symlink is fragile and often
  machine-specific. If the resolved target is **stale** — broken on this machine
  because it hardcodes another user's path (`/Users/<someone-else>/…`) — find the
  correct local equivalent and point there instead.

Also check `R/config.R` (or equivalent) to confirm paths are **repo-relative**.
If a script hardcodes an absolute Dropbox path instead, that's a separate fix —
flag it; symlinks alone won't redirect it.

### Phase 2 — Choose symlink granularity (and handle `.gitkeep`)

**Default: whole-directory symlinks.** Replace each data dir in the code repo
with a symlink to its Dropbox twin. This is what the user almost always wants:
the data *lives* in Dropbox, and new pipeline outputs auto-land there.

The wrinkle is the tracked `.gitkeep` placeholders. A dir like `cache/` is
gitignored (`cache/*`) except for `!cache/.gitkeep`, which exists so the empty
dir survives a fresh clone. You can't cleanly have both a tracked
`cache/.gitkeep` *and* `cache` as a symlink — git would see the placeholder as
deleted and the symlink as an ignored entry. Resolve it by **untracking the
placeholder** (`git rm cache/.gitkeep`): once the path is a symlink to a
populated Dropbox dir, it's never empty, so the placeholder has no job. The
setup script recreates the dirs/links on a fresh clone, which is what the
`.gitkeep` used to guarantee.

The alternative — keep the real dir + `.gitkeep`, symlink only the *existing
contents* — avoids touching committed files, but newly written files stay local
(not synced) and need periodic re-linking. Only choose this if the user
specifically wants zero committed changes and the dir isn't a write target.

When there's a genuine fork (whole-dir + untrack vs. contents-only), surface it
with a short `AskUserQuestion` rather than guessing — it changes committed files.

### Phase 3 — Write the setup script

Copy `assets/setup-symlinks.sh` into the **code repo root** and edit only the
link list near the bottom and the path roots near the top. The template already
encodes the things that are easy to get wrong:

- **Portable** — derives the Dropbox location from `$HOME`, so it works across
  machines and usernames (the coauthor with a different `/Users/<name>`), with a
  `DROPBOX_PROJ=…` override.
- **Idempotent** — safe to re-run; uses `ln -sfn` to refresh existing links.
- **Safe** — refuses to replace a real (non-symlink) directory unless it's empty
  or holds nothing but a `.gitkeep`. It will never clobber real data.
- **Skips missing targets** — warns instead of creating dangling links.

Make `setup-symlinks.sh` executable (`chmod +x`).

### Phase 4 — Update git bookkeeping

1. Untrack the placeholders you decided to drop:
   `git rm cache/.gitkeep data/raw/.gitkeep output/tables/.gitkeep …`
   (Skip for a brand-new repo — there are none yet.)
2. Make sure the **symlinks themselves** are ignored. If you're reconciling an
   existing `.gitignore`, note that an old `cache/*` + `!cache/.gitkeep` pattern
   does *not* ignore a symlink *named* `cache`; switch to root-anchored entries
   for each linked path. If you're authoring `.gitignore` fresh for a new repo,
   just add those entries directly:

   ```gitignore
   # Symlinked in from Dropbox by setup-symlinks.sh
   /cache
   /data/raw
   /data/reynier
   /dataverse_files
   /output/tables
   /output/figures
   ```
   Keep any already-correct ignores for other gitignored paths.

### Phase 5 — Run and verify

Run `./setup-symlinks.sh`, then verify — don't just trust the "OK" lines:

```bash
ls -la <each linked path>                 # every one resolves to its Dropbox target
test -e <linked-path>/<a-known-file> && echo OK   # data reachable through the link
git check-ignore <each linked path>       # every symlink is ignored
git status --short                         # only the intended changes show
```

For any link you repointed in Phase 1 (a resolved or stale symlink), confirm it
now lands on the **correct target** and the expected subtree is present — a quick
`test -d` is enough; you only need existence, not contents, to confirm a link works.

### Phase 6 — Document and commit

1. Update `README.md`: mark the symlinked dirs (a `→ Dropbox` note in the layout
   tree reads well), add a short paragraph explaining the code-only-repo + data-
   in-Dropbox architecture, and add a **Step 0 — run `./setup-symlinks.sh`** to
   the quickstart. Fix any old text describing the pre-migration structure.
2. Commit following the user's GitHub workflow (see their global `CLAUDE.md`):
   branch named for the issue if one exists, descriptive commit, draft PR that
   references the issue's progress. Match ceremony to scope.

## Verification checklist

- [ ] Every intended path is a symlink resolving to the Dropbox copy.
- [ ] Data is reachable through each link (existence-checked, not printed).
- [ ] Symlink points at the correct *local* target, not a stale path.
- [ ] `git check-ignore` reports every symlink as ignored.
- [ ] `git status` shows only intended changes (placeholder removals, `.gitignore`,
      new `setup-symlinks.sh`, README).
- [ ] `./setup-symlinks.sh` is idempotent (a second run reports OK, changes nothing).
- [ ] README documents the structure and the setup step.
