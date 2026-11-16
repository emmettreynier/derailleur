#!/usr/bin/env bash
# test-renv-seed.sh (offline) — seeding a fresh worktree's renv/library (issue #108).
#
# A `git worktree add` checkout has an EMPTY renv/library (renv gitignores it), so an
# renv-pinned repo whose stages stop on renv::status() fails in every fresh worker/checker
# worktree. bootstrap_worktree_data (bin/dispatch-common.sh, sourced by BOTH launchers)
# now copies the working clone's library in first, via seed_renv_library. Asserted here:
#
#   1. seeded when the worktree has renv.lock and an empty/missing library — as a COPY
#      (a real dir, not a symlink; writing into it leaves the clone's library untouched);
#   2. a reused worktree's non-empty library is left alone (not re-copied, not merged);
#   3. a clone with no library warns once and the dispatch continues (exit 0);
#   4. no renv.lock -> nothing is created and nothing is printed;
#   5. a failing copy warns once, continues, and leaves no partial library behind;
#   6. the manifest opt-out (seed_renv_library: false) seeds nothing;
#   7. both launchers' --dry-run print a `renv library` line only for an renv repo.
#
# All fixtures are synthetic: fake package dirs under mktemp sandboxes. No R is run.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

DISPATCH="$REPO_ROOT/bin/dispatch-common.sh"
assert_file_present "$DISPATCH" "dispatch-common.sh present" \
  "The shared bootstrap helper is missing from bin/."
# shellcheck source=/dev/null
. "$DISPATCH"

FIX="$(sandbox_tmp)"
CLONE="$FIX/clone"
# Synthetic clone library: renv's real layout is renv/library/<R-version>/<platform>/<pkg>.
LIB_LEAF="$CLONE/renv/library/R-4.4/aarch64-unknown-linux-gnu"
mkdir -p "$LIB_LEAF/synthpkg" "$CLONE/raw"
printf 'Package: synthpkg\nVersion: 0.0.1\n' >"$LIB_LEAF/synthpkg/DESCRIPTION"
ln -s synthpkg "$LIB_LEAF/synthlink"          # a symlink inside the library must survive
: >"$CLONE/raw/input.csv"
echo '{"R":{"Version":"4.4.0"}}' >"$CLONE/renv.lock"

# new_wt NAME [lock] — a fresh stand-in worktree; "lock" gives it an renv.lock.
new_wt() {
  local wt="$FIX/$1"; mkdir -p "$wt"
  [ "${2:-}" = lock ] && cp "$CLONE/renv.lock" "$wt/renv.lock"
  printf '%s' "$wt"
}
# boot WT [flag] — the real entry point, exactly as both launchers call it (code-only
# shape: raw_resolved == working_clone, so no data gate interferes).
boot() { bootstrap_worktree_data "$1" "$CLONE" "$CLONE" "" renv-demo "" "" "${2:-}"; }

# ── 1. seeded: renv.lock + no renv/library at all ─────────────────────────────────
wt="$(new_wt wt-fresh lock)"
rc=0; out="$(boot "$wt" 2>&1)" || rc=$?
assert_rc 0 "$rc" "seed: bootstrap exits 0 on a fresh renv worktree"
assert_contains "$out" "renv library: seeded from $CLONE/renv/library" \
  "seed: dispatch output says the library was seeded" \
  "seed_renv_library must print one 'renv library: seeded …' line — bin/dispatch-common.sh."
assert_file_present "$wt/renv/library/R-4.4/aarch64-unknown-linux-gnu/synthpkg/DESCRIPTION" \
  "seed: the clone's packages are in the worktree's renv/library"
assert_eq "synthpkg" "$(readlink "$wt/renv/library/R-4.4/aarch64-unknown-linux-gnu/synthlink")" \
  "seed: a symlink inside the library is preserved as a symlink"
if [ -L "$wt/renv/library" ]; then
  fail "seed: renv/library is a COPY, not a symlink" \
       "A shared library would let a worker mutate the clone's pinned packages (issue #108: copy, don't share)."
else
  pass "seed: renv/library is a COPY, not a symlink"
fi
echo mutated >"$wt/renv/library/R-4.4/aarch64-unknown-linux-gnu/synthpkg/DESCRIPTION"
assert_contains "$(cat "$LIB_LEAF/synthpkg/DESCRIPTION")" "Version: 0.0.1" \
  "seed: writing into the worktree's library leaves the clone's untouched"
assert_eq "" "$(ls -A "$wt/renv" | grep '^\.library-seed' || true)" \
  "seed: no temp copy is left beside the library"

# ── 1b. seeded: an EMPTY renv/library dir (a leftover) is replaced, not nested into ─
wt="$(new_wt wt-emptylib lock)"; mkdir -p "$wt/renv/library"
rc=0; out="$(boot "$wt" 2>&1)" || rc=$?
assert_rc 0 "$rc" "seed (empty dir): bootstrap exits 0"
assert_contains "$out" "renv library: seeded" "seed (empty dir): reported seeded"
assert_file_present "$wt/renv/library/R-4.4/aarch64-unknown-linux-gnu/synthpkg/DESCRIPTION" \
  "seed (empty dir): packages land at renv/library/<R>/…, not renv/library/library/…"

# ── 2. reused: a non-empty library is left alone ──────────────────────────────────
wt="$(new_wt wt-reused lock)"; mkdir -p "$wt/renv/library/R-4.4"
echo own >"$wt/renv/library/R-4.4/marker"
rc=0; out="$(boot "$wt" 2>&1)" || rc=$?
assert_rc 0 "$rc" "reuse: bootstrap exits 0"
assert_contains "$out" "renv library: reused" "reuse: dispatch output says the library was reused"
assert_not_contains "$out" "seeded" "reuse: nothing is re-copied"
assert_file_absent "$wt/renv/library/R-4.4/aarch64-unknown-linux-gnu" \
  "reuse: the clone's library is NOT merged into an existing one"
assert_eq "own" "$(cat "$wt/renv/library/R-4.4/marker")" "reuse: the worktree's own library is unchanged"
# A second dispatch to a just-seeded worktree also reports reuse (validation check 2).
wt="$FIX/wt-fresh"
out="$(boot "$wt" 2>&1)"
assert_contains "$out" "renv library: reused" "reuse: a second dispatch to a seeded worktree reports reused"

# ── 3. missing: the clone has no library -> one warning, dispatch continues ───────
NOLIB="$FIX/clone-nolib"; mkdir -p "$NOLIB"; cp "$CLONE/renv.lock" "$NOLIB/renv.lock"
wt="$(new_wt wt-nolib lock)"
rc=0; out="$(bootstrap_worktree_data "$wt" "$NOLIB" "$NOLIB" "" renv-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "missing: a clone with no renv/library does not abort the dispatch" \
  "The repo's own renv check is the hard gate; bootstrap must only warn (issue #108)."
assert_contains "$out" "⚠ renv library: missing" "missing: one clear warning is printed"
assert_contains "$out" "$NOLIB/renv/library" "missing: the warning names the clone's library path"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'renv library')" "missing: exactly one renv line"
assert_file_absent "$wt/renv/library" "missing: nothing is created in the worktree"

# ── 4. no renv.lock -> untouched and silent ───────────────────────────────────────
wt="$(new_wt wt-norenv)"
rc=0; out="$(boot "$wt" 2>&1)" || rc=$?
assert_rc 0 "$rc" "no renv.lock: bootstrap exits 0"
assert_not_contains "$out" "renv" "no renv.lock: nothing about renv is printed"
assert_file_absent "$wt/renv" "no renv.lock: no renv/ dir is created"

# ── 5. copy fails -> one warning, continues, no partial library ───────────────────
SHIM="$(sandbox_tmp)"
cat >"$SHIM/cp" <<'SH'
#!/usr/bin/env bash
# SYNTHETIC failing cp: makes a partial target, then fails — every strategy.
for a in "$@"; do last="$a"; done
mkdir -p "$last" && : >"$last/partial"
exit 1
SH
chmod +x "$SHIM/cp"
wt="$(new_wt wt-cpfail lock)"
rc=0; out="$(PATH="$SHIM:$PATH" boot "$wt" 2>&1)" || rc=$?
assert_rc 0 "$rc" "copy fails: bootstrap still exits 0"
assert_contains "$out" "⚠ renv library: copy failed" "copy fails: one clear warning is printed"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'renv library')" "copy fails: exactly one renv line"
assert_file_absent "$wt/renv/library" \
  "copy fails: no half-copied library is left for the next dispatch to 'reuse'"
assert_eq "" "$(ls -A "$wt/renv" 2>/dev/null | grep '^\.library-seed' || true)" \
  "copy fails: the temp copy is cleaned up"

# ── 6. manifest opt-out ───────────────────────────────────────────────────────────
for v in false FALSE no off 0; do
  wt="$(new_wt "wt-off-$v" lock)"
  out="$(boot "$wt" "$v" 2>&1)"
  assert_contains "$out" "renv library: not seeded (seed_renv_library: $v" \
    "opt-out: seed_renv_library: $v reports not seeded"
  assert_file_absent "$wt/renv/library" "opt-out: seed_renv_library: $v copies nothing"
done
wt="$(new_wt wt-on lock)"
out="$(boot "$wt" true 2>&1)"
assert_contains "$out" "renv library: seeded" "opt-in: seed_renv_library: true seeds"

# ── 7. launchers: the manifest key reaches bootstrap, and --dry-run previews it ────
for role in worker checker; do
  assert_contains "$(grep -n 'bootstrap_worktree_data "\$WORKTREE"' "$REPO_ROOT/bin/launch-$role.sh")" \
    '"$SEED_RENV_LIBRARY"' "launch-$role passes seed_renv_library to bootstrap_worktree_data" \
    "Both launchers must forward the manifest flag as bootstrap_worktree_data's 8th arg."
  assert_contains "$(cat "$REPO_ROOT/bin/launch-$role.sh")" 'SEED_RENV_LIBRARY="$(yml seed_renv_library)"' \
    "launch-$role reads seed_renv_library from the manifest"
done

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" launch-worker
sandbox_copy_script "$SB" launch-checker
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" config-common
cp -R "$REPO_ROOT/host" "$SB/host"
cp -R "$REPO_ROOT/templates" "$SB/templates"
cp "$REPO_ROOT/briefs/worker-brief.md" "$REPO_ROOT/briefs/checker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-worker.sh" "$SB/bin/launch-checker.sh"
GHDIR="$(sandbox_tmp)"
cat >"$GHDIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"isDraft":false,"headRefName":"issue-108","closingIssuesReferences":[{"number":108}],"state":"OPEN"}'
SH
chmod +x "$GHDIR/gh"
PLAIN="$FIX/clone-plain"; mkdir -p "$PLAIN"
write_m() {  # $1 slug, $2 clone, $3 extra line
  {
    echo "repo: test-operator/renv-demo"
    echo "working_clone: $2"
    echo "worktrees_dir: $FIX/dry-wt"
    echo "data_root: $2"
    echo "raw_resolved: $2"
    [ -n "${3:-}" ] && echo "$3"
    echo "raw_paths: []"
    echo "output_paths: []"
  } >"$SB/projects/$1.yml"
}
write_m renv-on "$CLONE"
write_m renv-off "$CLONE" "seed_renv_library: false   # opt out"
write_m plain "$PLAIN"
dry() { PATH="$GHDIR:$PATH" "$SB/bin/launch-$1.sh" "$2" 108 --dry-run 2>&1 \
          | LC_ALL=C sed -n '/^# DRY RUN/,/^# Assembled command:/p'; }
for role in worker checker; do
  blk="$(dry "$role" renv-on)"
  assert_contains "$blk" "#   renv library  : would seed from $CLONE/renv/library" \
    "dry-run ($role): an renv repo previews the seed"
  blk="$(dry "$role" renv-off)"
  assert_contains "$blk" "#   renv library  : off (seed_renv_library: false)" \
    "dry-run ($role): the opt-out is shown (trailing #comment stripped)"
  blk="$(dry "$role" plain)"
  assert_not_contains "$blk" "renv library" \
    "dry-run ($role): a repo without renv.lock prints no renv line (byte-identical to before)"
done
