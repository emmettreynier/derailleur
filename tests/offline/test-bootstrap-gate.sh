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

# --- helper: build a throwaway branch-(a) worktree that ships its own setup-symlinks.sh
# creating one top-level dir with a space in its name (mirrors distance-decay-est's
# "06 Raw_data"). bootstrap_worktree_data runs this script itself (cd'd into the worktree),
# so it need not be pre-run here. Pass 1 to create a real "06 Raw_data" dir, 0 to SKIP it
# (leaving the critical path absent so the gate can fire).
make_ownscript_wt() {
  local wt="$1" make_target="$2"
  mkdir -p "$wt"
  if [ "$make_target" = 1 ]; then
    cat > "$wt/setup-symlinks.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$PWD/../ownscript-shared/06 Raw_data"; : > "$PWD/../ownscript-shared/06 Raw_data/x.csv"
ln -sfn "$PWD/../ownscript-shared/06 Raw_data" "$PWD/06 Raw_data"
echo "  OK    06 Raw_data -> ../ownscript-shared"
SH
  else
    cat > "$wt/setup-symlinks.sh" <<'SH'
#!/usr/bin/env bash
echo "  SKIP  06 Raw_data (target missing)"
SH
  fi
  chmod +x "$wt/setup-symlinks.sh"
}

# state 5 — own setup-symlinks.sh, NO critical_paths declared: a branch-(a) repo uses its
# own link names and never scaffolds the generic data/raw. It must NOT be hard-failed on
# the generic path (issue #43 reverses the #44 warning but keeps the no-false-positive
# invariant): the gate proceeds (rc 0) and prints a note steering the operator to declare
# critical_paths. There is a real, populated raw_resolved (an unrelated shared tree).
g_wt="$GROOT/wt-ownscript-nocp"
make_ownscript_wt "$g_wt" 1
g_raw="$GROOT/raw-ownscript"; mkdir -p "$g_raw"; : >"$g_raw/input.csv"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: own setup-symlinks.sh, no critical_paths → proceeds (no data/raw hard-fail)" \
  "A branch-(a) repo declaring no critical_paths must not be hard-failed on the generic data/raw path — bin/dispatch-common.sh."
assert_contains "$out" "critical_paths" "bootstrap gate: own-script/no-cp case steers to critical_paths" \
  "The note should tell the operator to declare critical_paths to gate a branch-(a) repo — bin/dispatch-common.sh."
assert_file_absent "$g_wt/data/raw" "bootstrap gate: own-script case scaffolds no generic data/raw link" \
  "bootstrap_worktree_data must defer entirely to the repo's own script in this branch."

# state 6 — own setup-symlinks.sh + declared critical_paths that RESOLVE: the repo's own
# script created "06 Raw_data", the manifest declares it critical, and the gate finds it —
# dispatch proceeds (rc 0), no abort. Exercises the comma-split + space-in-name path.
g_wt="$GROOT/wt-ownscript-ok"
make_ownscript_wt "$g_wt" 1
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo "06 Raw_data" 2>&1)" || rc=$?
assert_rc 0 "$rc" "bootstrap gate: branch-(a) + resolving critical_paths → proceeds" \
  "A declared critical path that resolves to a real dir must pass the gate cleanly — bin/dispatch-common.sh."

# state 7 — own setup-symlinks.sh + declared critical_paths that DON'T resolve: the target
# was never created, so "06 Raw_data" is a dangling link; the gate must ABORT non-zero,
# naming the offending path and pointing at critical_paths in the manifest.
g_wt="$GROOT/wt-ownscript-broken"
make_ownscript_wt "$g_wt" 0
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo "06 Raw_data, 07 Dataclean" 2>&1)" || rc=$?
assert_ne 0 "$rc" "bootstrap gate: branch-(a) + broken critical_paths aborts non-zero" \
  "A declared critical path that doesn't resolve must abort the dispatch — bin/dispatch-common.sh."
assert_contains "$out" "06 Raw_data" "bootstrap gate: critical_paths abort names the offending path" \
  "The abort message must print the declared path that failed to resolve — bin/dispatch-common.sh."
assert_contains "$out" "critical_paths in projects/gate-demo.yml" "bootstrap gate: critical_paths abort points at the manifest field" \
  "The abort message must name critical_paths in the manifest so the operator can fix it — bin/dispatch-common.sh."

# state 8 — declared critical_paths take precedence over the generic default: even a
# branch-(b) worktree (no own script) with a healthy raw_resolved must ABORT when a
# declared critical path is missing. Guards against the gate silently ignoring the field.
g_wt="$GROOT/wt-cp-precedence"; mkdir -p "$g_wt"
g_raw="$GROOT/raw-cp"; mkdir -p "$g_raw"; : >"$g_raw/input.csv"
rc=0; out="$(bootstrap_worktree_data "$g_wt" "$g_raw" "$G_CLONE" "" gate-demo "never-created-dir" 2>&1)" || rc=$?
assert_ne 0 "$rc" "bootstrap gate: declared critical_paths override the data/raw default" \
  "critical_paths must be asserted even when raw_resolved is healthy — bin/dispatch-common.sh."
