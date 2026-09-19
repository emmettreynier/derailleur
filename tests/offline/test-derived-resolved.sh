#!/usr/bin/env bash
# test-derived-resolved.sh (offline) — the optional `derived_resolved` manifest key
# (hub project-management-v2#38 part (d)): a shared, WRITABLE data/derived tree.
#
# Two properties matter and both are asserted here:
#
#   1. Set  -> data/derived is symlinked and stays writable even when the manifest
#      blanket-protects the whole data tree as raw. Without the carveout a worker whose
#      issue is "build the panel" would be denied mid-issue by the raw guard.
#   2. Unset -> nothing changes AT ALL. No link, and no writable carveout leaks. This is
#      the non-breaking contract: every pre-existing manifest omits the key, so the
#      launcher's assembled command must stay byte-identical to before it existed.
#
# Property 2 is the one worth regression-testing hardest — an accidental unconditional
# carveout would silently make derived/ writable in repos that never asked for it, and
# in a repo whose raw_paths is `.` that means punching a hole in raw protection itself.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

GUARD="$REPO_ROOT/host/hooks/raw-data-guard.py"
DISPATCH="$REPO_ROOT/bin/dispatch-common.sh"
assert_file_present "$GUARD" "raw-data-guard.py present" \
  "The deny-hook is missing from host/hooks/."
assert_file_present "$DISPATCH" "dispatch-common.sh present" \
  "The shared bootstrap helper is missing from bin/."

# ---------------------------------------------------------------------------
# Fixture: a data tree where the ENTIRE tree is declared raw (`raw_paths: [.]`),
# which is the strictest case — derived/ can only be writable via a real carveout.
# ---------------------------------------------------------------------------
FIX="$(sandbox_tmp)"
mkdir -p "$FIX/data/raw" "$FIX/data/derived" "$FIX/clone"

write_manifest() {  # $1 = out path; $2 = derived_resolved value ("" = omit the key)
  {
    echo "repo: emmettreynier/fake"
    echo "working_clone: $FIX/clone"
    echo "worktrees_dir: $FIX/wt"
    echo "data_root: $FIX/data"
    echo "raw_resolved: $FIX/data/raw"
    [ -n "$2" ] && echo "derived_resolved: $2"
    echo "raw_paths:"
    echo "  - ."
    echo "output_paths:"
    echo "  - data/results/"
  } >"$1"
}
write_manifest "$FIX/with.yml" "$FIX/data/derived"
write_manifest "$FIX/without.yml" ""

# guard_write MANIFEST PATH — echo the hook's stdout for a Write to PATH.
guard_write() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$2" "$FIX/clone" \
    | ORCH_MANIFEST="$1" python3 "$GUARD" 2>/dev/null || true
}

out="$(guard_write "$FIX/with.yml" "$FIX/data/derived/panel.qd")"
assert_not_contains "$out" '"permissionDecision": "deny"' \
  "derived_resolved SET: a write under data/derived is allowed" \
  "The carveout in load_writable_prefixes() is not reaching derived_resolved."

out="$(guard_write "$FIX/without.yml" "$FIX/data/derived/panel.qd")"
assert_contains "$out" '"permissionDecision": "deny"' \
  "derived_resolved UNSET: a write under data/derived is still denied" \
  "A writable carveout leaked to manifests that never set the key — that is a hole in raw protection."

out="$(guard_write "$FIX/with.yml" "$FIX/data/raw/mortality.csv")"
assert_contains "$out" '"permissionDecision": "deny"' \
  "derived_resolved SET: raw data is STILL read-only" \
  "The derived carveout must never widen to the raw tree (design.md principle 5)."
assert_contains "$out" 'data/derived/' \
  "the deny message names data/derived/ as a legal write target" \
  "A denied worker needs to be told where it may write instead."

# ---------------------------------------------------------------------------
# bootstrap_worktree_data — the symlink half.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$DISPATCH"

wt="$FIX/wt-set"; mkdir -p "$wt"
bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" "$FIX/data/derived" >/dev/null 2>&1 || true
assert_file_present "$wt/data/derived" "key SET: data/derived is provisioned" \
  "bootstrap_worktree_data did not create the shared derived link."
assert_eq "$FIX/data/derived" "$(readlink "$wt/data/derived")" \
  "key SET: data/derived points at derived_resolved"
assert_file_present "$wt/data/raw" "key SET: data/raw is still provisioned"

wt="$FIX/wt-unset"; mkdir -p "$wt"
bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" "" >/dev/null 2>&1 || true
assert_file_absent "$wt/data/derived" "key UNSET: no data/derived link is created" \
  "An unset key must leave worktree provisioning exactly as it was."
assert_file_present "$wt/data/raw" "key UNSET: data/raw is unaffected"

# A stale/typo'd path must warn loudly and link nothing, rather than creating a dangling
# symlink that later reads as "derived exists" and fails deep inside a pipeline stage.
wt="$FIX/wt-missing"; mkdir -p "$wt"
err="$(bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" \
       "$FIX/data/does-not-exist" 2>&1 >/dev/null || true)"
assert_contains "$err" "does not resolve to a directory" \
  "key SET but target missing: warns" \
  "A misconfigured derived_resolved must be surfaced, not swallowed."
assert_file_absent "$wt/data/derived" \
  "key SET but target missing: no dangling symlink is created" \
  "A dangling data/derived is worse than none — it looks provisioned."

# `ln -sfn` only declines to dereference a SYMLINK destination. Against a pre-existing REAL
# directory it links INSIDE it, so sharing silently does not happen and the worker writes a
# private local dir — the #25 failure class. Both shapes of that collision are pinned here.
wt="$FIX/wt-realdir-empty"; mkdir -p "$wt/data/derived"
bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" "$FIX/data/derived" >/dev/null 2>&1 || true
assert_eq "$FIX/data/derived" "$(readlink "$wt/data/derived" 2>/dev/null || echo NOT-A-SYMLINK)" \
  "pre-existing EMPTY data/derived is replaced by the shared symlink" \
  "An empty leftover mkdir -p must not make the link nest inside it."

wt="$FIX/wt-realdir-full"; mkdir -p "$wt/data/derived"; touch "$wt/data/derived/.gitkeep"
rc=0
err="$(bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" \
        "$FIX/data/derived" 2>&1 >/dev/null)" || rc=$?
assert_rc 1 "$rc" \
  "pre-existing NON-EMPTY data/derived aborts the dispatch" \
  "Sharing cannot be provisioned here; proceeding would silently share nothing (#25 class)."
assert_contains "$err" "nest the link inside it" \
  "the abort explains the nesting failure it prevented"
assert_file_absent "$wt/data/derived/$(basename "$FIX/data/derived")" \
  "no nested link is left behind inside the real directory" \
  "This is the exact artifact the bug produced: data/derived/<basename> instead of the link."

# A repo shipping its own setup-symlinks.sh owns the whole data/ layout, so the key is inert
# there. Defensible as a design choice, indefensible as a SILENT one: most pre-standard repos
# are branch (a), so an operator who set the key would believe worktrees share a derived tree
# while each quietly kept its own. The warning is the contract.
wt="$FIX/wt-own-script"; mkdir -p "$wt"
printf '#!/usr/bin/env bash\nexit 0\n' >"$wt/setup-symlinks.sh"
chmod +x "$wt/setup-symlinks.sh"
err="$(bootstrap_worktree_data "$wt" "$FIX/data/raw" "$FIX/clone" "" fake-slug "" \
        "$FIX/data/derived" 2>&1 >/dev/null || true)"
assert_contains "$err" "derived_resolved is set but IGNORED" \
  "branch (a) repo: an inert derived_resolved is reported, not silently skipped" \
  "A silent no-op here is the #25 class one layer up — the operator believes sharing is on."
assert_file_absent "$wt/data/derived" \
  "branch (a) repo: no data/derived link is fabricated" \
  "The repo's own script owns this path; the launcher must not fight it."

# ---------------------------------------------------------------------------
# The key is documented in the tracked template (real manifests are gitignored,
# so the template is the only place an onboarder can learn the key exists).
# ---------------------------------------------------------------------------
tpl="$(cat "$REPO_ROOT/templates/project.yml")"
assert_contains "$tpl" "setup-symlinks.sh" \
  "templates/project.yml documents the branch-(a) limitation where the key is inert" \
  "Without this, the key reads as universally available; 4 of 6 real manifests are branch (a)."
assert_contains "$tpl" "derived_resolved" \
  "templates/project.yml documents derived_resolved"
assert_contains "$tpl" "research-template" \
  "templates/project.yml names research-template as the standard it enforces"
assert_matches "$tpl" 'misc/' \
  "templates/project.yml records why misc/ is not provisioned into worktrees"
