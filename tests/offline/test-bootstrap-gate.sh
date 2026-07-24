#!/usr/bin/env bash
# test-bootstrap-gate.sh (offline) — bootstrap_worktree_data critical raw-link gate.
# The host-side gate (dispatch-common.sh, issue #35, defense-in-depth for #25) hard-fails
# a dispatch when a data-backed worktree's critical data/raw symlink doesn't resolve — so a
# worker/checker never computes on missing inputs and exits 0 (the #25 silent failure).
# bootstrap_worktree_data is sourced by BOTH launchers, so one test covers worker+checker.
# Pure and offline: source the function, call it against throwaway worktree fixtures for all
# four states, assert exit code + message. No network, nothing dispatched, nothing spent.
# Ported from the retired bin/smoke-test.sh case PR #38 added (issue #31, block G).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/dispatch-common.sh" "bin/dispatch-common.sh present" \
  "The shared launcher logic (bootstrap_worktree_data) is missing from bin/."

# shellcheck source=/dev/null
. "$REPO_ROOT/bin/dispatch-common.sh"

GROOT="$(sandbox_tmp)"
G_CLONE="$GROOT/clone"; mkdir -p "$G_CLONE"        # stand-in working clone (a distinct real path)

# state 1 — missing/broken: raw_resolved points at a path that doesn't exist, so the
# default-template branch creates a DANGLING data/raw symlink. The gate must abort
# non-zero, naming the unresolved path AND the manifest to fix.
g_wt="$GROOT/wt-broken"; mkdir -p "$g_wt"
g_raw="$GROOT/nonexistent-raw"                     # deliberately never created
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_ne 0 "$rc" "bootstrap gate: missing/broken data/raw aborts non-zero" \
  "bootstrap_worktree_data must return 1 when the critical raw link doesn't resolve — bin/dispatch-common.sh."
assert_contains "$out" "$g_raw" "bootstrap gate: abort names the unresolved raw path" \
  "The abort message must print the raw path that failed to resolve — bin/dispatch-common.sh."
assert_contains "$out" "projects/gate-demo.yml" "bootstrap gate: abort points at projects/<slug>.yml" \
  "The abort message must name the manifest so the operator can fix raw_resolved."

# state 2 — populated: a real, non-empty raw dir; dispatch proceeds (exit 0), the link
# gets created, and there is no new abort output.
g_wt="$GROOT/wt-pop"; mkdir -p "$g_wt"
g_raw="$GROOT/raw-pop"; mkdir -p "$g_raw"; : >"$g_raw/input.csv"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: populated data/raw exits 0" \
  "A populated raw tree must pass the gate cleanly — bin/dispatch-common.sh."
assert_file_present "$g_wt/data/raw" "bootstrap gate: populated raw tree gets a data/raw link" \
  "The default-template branch should symlink data/raw -> raw_resolved."

# state 3 — empty: a real but empty raw dir; dispatch proceeds (exit 0, no abort) AND
# prints a single-line informational note (a legit-empty raw tree needs no .gitkeep).
g_wt="$GROOT/wt-empty"; mkdir -p "$g_wt"
g_raw="$GROOT/raw-empty"; mkdir -p "$g_raw"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: empty data/raw exits 0 (legit-empty needs no .gitkeep)" \
  "An empty-but-resolving raw tree must proceed, not abort — bin/dispatch-common.sh."
assert_contains "$out" "empty" "bootstrap gate: empty raw tree prints an informational note" \
  "An empty raw tree should proceed AND print a single-line note that it is empty."

# state 4 — code-only: raw_resolved == working_clone (a self-hosting manifest). No
# data/raw link is scaffolded and the gate must NOT fire.
g_wt="$GROOT/wt-codeonly"; mkdir -p "$g_wt"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$G_CLONE" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: code-only manifest exits 0 (gate skipped)" \
  "The gate must skip when raw_resolved resolves to the working clone — bin/dispatch-common.sh."
assert_file_absent "$g_wt/data/raw" "bootstrap gate: code-only manifest scaffolds no data/raw link" \
  "raw_resolved == working_clone must skip the data/raw scaffold entirely."

# state 5 — own setup-symlinks.sh, doesn't scaffold data/raw: a repo that ships its own
# setup-symlinks.sh (e.g. distance-decay-est) uses its own link names, never data/raw.
# The generic data/raw invariant doesn't apply — the gate must WARN, not abort (hotfix,
# 2026-07-24: the prior hard-fail blocked every dispatch to such a repo).
g_wt="$GROOT/wt-ownscript"; mkdir -p "$g_wt"
cat > "$g_wt/setup-symlinks.sh" <<'SH'
#!/usr/bin/env bash
echo "  OK    some-other-link -> somewhere"
SH
chmod +x "$g_wt/setup-symlinks.sh"
g_raw="$GROOT/raw-ownscript"; mkdir -p "$g_raw"; : >"$g_raw/input.csv"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: own setup-symlinks.sh with no data/raw warns, doesn't abort" \
  "A repo shipping its own setup-symlinks.sh must not be hard-failed on the generic data/raw path — bin/dispatch-common.sh."
assert_contains "$out" "own setup-symlinks.sh" "bootstrap gate: own-script case prints an explanatory warning" \
  "The warning should explain why the generic data/raw check doesn't apply — bin/dispatch-common.sh."
assert_file_absent "$g_wt/data/raw" "bootstrap gate: own-script case scaffolds no generic data/raw link" \
  "bootstrap_worktree_data must defer entirely to the repo's own script in this branch."
