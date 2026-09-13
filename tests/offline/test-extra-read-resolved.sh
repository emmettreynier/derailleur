#!/usr/bin/env bash
# test-extra-read-resolved.sh (offline) — the optional, list-valued `extra_read_resolved`
# manifest key (issue #74): additional READ-ONLY trees appended to the assembled
# `--add-dir` scope, without widening the scalar `raw_resolved`.
#
# Mirrors tests/offline/test-derived-resolved.sh, which is the precedent this key follows.
# Two properties matter and both are asserted here, in both launchers:
#
#   1. Set   -> one `--add-dir <path>` per entry, in manifest order, appended AFTER
#      raw_resolved and derived_resolved; plus a distinctly-labelled dry-run line each.
#   2. Unset -> nothing changes AT ALL. The `--add-dir` vector is exactly what it was
#      before the key existed, and the dry-run block gains no line. This is the
#      non-breaking contract: 8 of the 9 real manifests omit the key.
#
# HOW "byte-identical" IS ASSERTED. The key is purely additive — it touches nothing but
# the `--add-dir` vector and one dry-run line — so byte-identity with the pre-change
# command reduces to: the unset vector is EXACTLY the pre-change one (worker: worktree,
# raw [, derived]; checker: worktree, raw, logs [, derived]) and no extra line is printed.
# Both are pinned below as exact, whole-vector equality against a literal built here, not
# as a "contains" check — a "contains" would pass even if a stray --add-dir leaked in.
#
# The third property is a SAFETY one: read scope only. The key must not become a write
# carveout, so the deny-hook must still deny a write under an extra_read_resolved tree.
# Without that assertion, a future "while we're here" carveout would silently make an
# extra raw tree writable in the one repo that uses the key — on glyphosate-htbt, that
# tree is 333 MB of raw USGS input that nothing regenerates.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

GUARD="$REPO_ROOT/host/hooks/raw-data-guard.py"
assert_file_present "$GUARD" "raw-data-guard.py present" \
  "The deny-hook is missing from host/hooks/."

# --- shared sandbox: a throwaway ORCH both launchers resolve as their repo root -----
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

# Fixture data tree: a narrow public raw/, two more public input trees, and a restricted
# one that must never end up in scope (the glyphosate-htbt shape, in miniature).
FIX="$(sandbox_tmp)"
CLONE="$FIX/clone"; WTS="$FIX/wt"
mkdir -p "$CLONE" "$WTS" "$FIX/data/raw" "$FIX/data/derived" \
         "$FIX/data/download-script" "$FIX/data/download-manual" "$FIX/data/health-restricted"

# Stub `gh` so the checker's one `gh pr view --json …` resolves offline to an OPEN,
# ready PR closing #74 (same technique as test-agent-deny.sh).
GHDIR="$(sandbox_tmp)"
cat >"$GHDIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"isDraft":false,"headRefName":"issue-74","closingIssuesReferences":[{"number":74}],"state":"OPEN"}'
SH
chmod +x "$GHDIR/gh"

# write_manifest OUT DERIVED EXTRA... — DERIVED "" omits derived_resolved; with no EXTRA
# args the extra_read_resolved key is omitted ENTIRELY (the 8-of-9 case).
write_manifest() {
  local out="$1" derived="$2"; shift 2
  {
    echo "repo: test-operator/extra-read-demo"
    echo "working_clone: $CLONE"
    echo "worktrees_dir: $WTS"
    echo "data_root: $FIX/data"
    echo "raw_resolved: $FIX/data/raw"
    [ -n "$derived" ] && echo "derived_resolved: $derived"
    if [ "$#" -gt 0 ]; then
      echo "extra_read_resolved:"
      # Deliberately shot through with the shapes the parser must tolerate: a trailing
      # `#` comment, a whole-line comment, and a blank line inside the block.
      echo "  # additional PUBLIC read-only trees (never restricted data)"
      local e
      for e in "$@"; do
        echo ""
        echo "  - $e   # why this tree is needed"
      done
    fi
    echo "raw_paths:"
    echo "  - ."
    echo "output_paths:"
    echo "  - data/results/"
  } >"$out"
}

# add_dirs ROLE MANIFEST_SLUG — echo the assembled `--add-dir` VALUES, one per line, in
# order, extracted from the launcher's printed command. It is printed as a single line by
# `printf '  %q'`, i.e. shell-quoted args joined by TWO spaces, so the value is whatever
# follows the flag up to the next space (sandbox fixture paths contain none). LC_ALL=C
# throughout: the rendered brief carries em-dashes, and `tr`/`grep` on some locales abort
# with "Illegal byte sequence" rather than matching, which would read as an empty vector.
add_dirs() {
  local role="$1" slug="$2" out
  out="$(PATH="$GHDIR:$PATH" "$SB/bin/launch-$role.sh" "$slug" 74 --dry-run 2>&1)" || return 1
  LC_ALL=C sed -n '/^# Assembled command:/,$p' <<<"$out" \
    | LC_ALL=C grep -o -- '--add-dir  *[^ ]*' \
    | LC_ALL=C sed -E 's/^--add-dir[[:space:]]+//'
  return 0
}

# dry_block ROLE SLUG — echo just the launcher's `#   key : value` info block.
dry_block() {
  local role="$1" slug="$2" out
  out="$(PATH="$GHDIR:$PATH" "$SB/bin/launch-$role.sh" "$slug" 74 --dry-run 2>&1)" || return 1
  LC_ALL=C sed -n '/^# DRY RUN/,/^# Assembled command:/p' <<<"$out"
  return 0
}

WT="$WTS/issue-74"
# The launcher resolves its own root with `cd … && pwd`, which normalizes the `//` that
# mktemp leaves when TMPDIR has a trailing slash — so normalize here too, or the
# comparison fails on a cosmetic slash rather than on real behavior.
LOGS="$(cd "$SB" && pwd)/logs"
X1="$FIX/data/download-script"
X2="$FIX/data/download-manual"

# ===================================================================================
# UNSET — the non-breakage contract. Asserted for a manifest WITHOUT derived_resolved
# and one WITH it, because the extra dirs are appended after derived and an off-by-one
# there would only show up in the second case.
# ===================================================================================
write_manifest "$SB/projects/plain.yml" ""
write_manifest "$SB/projects/plain-derived.yml" "$FIX/data/derived"

assert_eq "$(printf '%s\n%s' "$WT" "$FIX/data/raw")" "$(add_dirs worker plain)" \
  "key UNSET (no derived): worker --add-dir vector is exactly worktree + raw" \
  "An unset extra_read_resolved must leave the assembled command byte-identical to before the key existed (#74)."
assert_eq "$(printf '%s\n%s\n%s' "$WT" "$FIX/data/raw" "$FIX/data/derived")" \
  "$(add_dirs worker plain-derived)" \
  "key UNSET (derived set): worker vector is exactly worktree + raw + derived" \
  "The #38 derived_resolved behavior must survive the #74 addition unchanged."
assert_eq "$(printf '%s\n%s\n%s' "$WT" "$FIX/data/raw" "$LOGS")" "$(add_dirs checker plain)" \
  "key UNSET (no derived): checker vector is exactly worktree + raw + logs" \
  "The checker's logs/ carveout must be the only extra --add-dir when the key is unset."
assert_eq "$(printf '%s\n%s\n%s\n%s' "$WT" "$FIX/data/raw" "$LOGS" "$FIX/data/derived")" \
  "$(add_dirs checker plain-derived)" \
  "key UNSET (derived set): checker vector is exactly worktree + raw + logs + derived"

for role in worker checker; do
  assert_not_contains "$(dry_block "$role" plain-derived)" "extra read" \
    "key UNSET: the $role dry-run block prints no extra-read line" \
    "A line printed unconditionally would break dry-run byte-identity for the 8 manifests that omit the key."
done

# ===================================================================================
# SET — one --add-dir per entry, in manifest order, appended last.
# ===================================================================================
write_manifest "$SB/projects/extra.yml" "$FIX/data/derived" "$X1" "$X2"
write_manifest "$SB/projects/extra-noderived.yml" "" "$X1"

assert_eq "$(printf '%s\n%s\n%s\n%s\n%s' "$WT" "$FIX/data/raw" "$FIX/data/derived" "$X1" "$X2")" \
  "$(add_dirs worker extra)" \
  "key SET: worker appends one --add-dir per entry, in order, after raw + derived" \
  "Both entries must appear, in manifest order, and only after raw_resolved/derived_resolved (#74)."
assert_eq "$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$WT" "$FIX/data/raw" "$LOGS" "$FIX/data/derived" "$X1" "$X2")" \
  "$(add_dirs checker extra)" \
  "key SET: checker appends the same entries, in the same order" \
  "The two launchers build ADD_DIRS identically and must stay in step, or a checker cannot re-run a validation check that reads the extra tree."
assert_eq "$(printf '%s\n%s\n%s' "$WT" "$FIX/data/raw" "$X1")" \
  "$(add_dirs worker extra-noderived)" \
  "key SET without derived_resolved: the entry still lands, right after raw" \
  "The two optional keys must be independent — neither may require the other."

# The dry-run must NAME each extra path on its own line, labelled distinctly from
# `raw (RO)` and `derived` so an operator can see it is a read-scope-only addition.
for role in worker checker; do
  blk="$(dry_block "$role" extra)"
  assert_contains "$blk" "extra read" \
    "key SET: the $role dry-run labels the extra trees 'extra read'" \
    "The label must be visibly distinct from 'raw (RO)' and 'derived' (#74)."
  assert_contains "$blk" "$X1" "key SET: the $role dry-run names the first extra tree"
  assert_contains "$blk" "$X2" "key SET: the $role dry-run names the second extra tree"
  assert_eq 2 "$(LC_ALL=C grep -c 'extra read' <<<"$blk" | tr -d ' ')" \
    "key SET: the $role dry-run prints one line per entry (2 entries -> 2 lines)" \
    "Each extra read path must get its own line, not a joined one."
done

# ===================================================================================
# NO TRAILING NEWLINE — the last line of a manifest is a list entry and the file does
# not end in `\n`. The block matcher repeats a `\n`-terminated line, so without an
# explicit tail for the un-terminated final line that entry is silently dropped: a
# read tree absent from scope, an output_paths entry missing from the brief, or — the
# one that matters — a critical_paths entry the #43 bootstrap raw-link gate then stops
# gating. Editors usually add the newline, which is exactly why this needs a net
# rather than a convention. (The narrower pre-#74 pattern's `\n?` handled this; the
# widening that bought comment/blank-line tolerance regressed it. Checker finding W1.)
# ===================================================================================
write_manifest "$SB/projects/nonl.yml" "" "$X1"
# Re-emit the same manifest with the final list entry LAST and no terminating newline.
{
  # Drop the original block (it sits before raw_paths) so the re-emitted one below is
  # the only extra_read_resolved key in the file, not a shadowed duplicate.
  LC_ALL=C sed -e '/^extra_read_resolved:/,$d' "$SB/projects/nonl.yml"
  echo "raw_paths:"
  echo "  - ."
  echo "output_paths:"
  echo "  - data/results/"
  echo "extra_read_resolved:"
  printf '  - %s' "$X1"          # no trailing newline, deliberately
} >"$SB/projects/nonl2.yml"
# `$(...)` strips trailing newlines, so a file that DOES end in one yields the empty
# string here and a file that does not yields its final byte — hence assert_ne "".
assert_ne "" "$(tail -c 1 "$SB/projects/nonl2.yml")" \
  "fixture: the no-trailing-newline manifest really has none" \
  "If the fixture ends in a newline the assertions below pass vacuously."

for role in worker checker; do
  assert_contains "$(add_dirs "$role" nonl2)" "$X1" \
    "manifest with NO trailing newline: the final list entry still reaches $role scope" \
    "A list entry on an un-terminated final line must not be dropped — it is silent in all three consumers of yml_list (critical_paths/#43 gate, output_paths, extra_read_resolved)."
done
# The same file, parsed for a key whose block is NOT last, must be unaffected.
assert_eq "$(add_dirs worker nonl)" "$(add_dirs worker nonl2)" \
  "no-trailing-newline manifest yields the same vector as the newline-terminated one" \
  "The tail added for the un-terminated case must not change parsing of a normal manifest."

# ===================================================================================
# READ SCOPE ONLY — the key must never become a write carveout. host/hooks/raw-data-guard.py
# does not read it at all, and this is the assertion that keeps it that way.
# ===================================================================================
guard_write() {  # $1 = manifest; $2 = target path
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$2" "$CLONE" \
    | ORCH_MANIFEST="$1" python3 "$GUARD" 2>/dev/null || true
}
out="$(guard_write "$SB/projects/extra.yml" "$X1/usgs-pesticides-raw.fst")"
assert_contains "$out" '"permissionDecision": "deny"' \
  "key SET: a write under an extra_read_resolved tree is STILL denied" \
  "extra_read_resolved grants --add-dir READ scope only; it must never carve out a writable prefix (#74)."
assert_not_contains "$(cat "$GUARD")" "extra_read_resolved" \
  "the deny-hook does not read extra_read_resolved at all" \
  "The key is read-scope-only by construction: host/hooks/raw-data-guard.py must stay untouched."

# ===================================================================================
# A restricted sibling tree stays out of scope. The whole point of the key is that it
# is NARROWER than repointing raw_resolved at the data/ parent — which would sweep
# health-restricted/ into every worker's read scope.
# ===================================================================================
for role in worker checker; do
  assert_not_contains "$(add_dirs "$role" extra)" "$FIX/data/health-restricted" \
    "key SET: an unlisted sibling tree (health-restricted) is NOT in $role scope" \
    "--add-dir scoping is the read-protection for restricted data; the key must add only what it names (#74)."
done

# ===================================================================================
# The key is documented in the tracked template + README — real manifests are gitignored,
# so those are the only places an onboarder can learn the key exists, and the
# never-for-restricted-data warning is the load-bearing half of that documentation.
# ===================================================================================
tpl="$(cat "$REPO_ROOT/templates/project.yml")"
assert_contains "$tpl" "extra_read_resolved" \
  "templates/project.yml documents extra_read_resolved"
assert_matches "$tpl" 'NEVER USE THIS TO EXPOSE CONFIDENTIAL' \
  "templates/project.yml warns the key must never expose confidential/restricted data" \
  "This key IS an --add-dir, i.e. exactly the lever that defeats read-protection — the warning is the contract."
assert_contains "$tpl" "glyphosate-htbt" \
  "templates/project.yml names the worked example manifest" \
  "The issue asks for projects/glyphosate-htbt.yml as the named worked example (#74)."
assert_contains "$(cat "$REPO_ROOT/README.md")" "extra_read_resolved" \
  "README.md's manifest-key documentation covers extra_read_resolved"
