#!/usr/bin/env bash
# test-schedule-enable-disable.sh (offline) — schedule.sh enable/disable maintaining
# the autonomous-dispatch allow-list (state/scheduled-repos). New coverage for the
# allow-list PR #33 (issue #31). Sandbox ORCH + fixture projects/*.yml + a
# SCHEDULED_REPOS_FILE override; touches no real state.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" schedule
SCHED="$SB/bin/schedule.sh"
FIX="$SB/state/scheduled-repos"

# Two onboarded slugs (manifests present) + one that is NOT onboarded.
write_project_manifest "$SB" solar-income owner/solar
write_project_manifest "$SB" glyphosate-health owner/glyph

# Run schedule.sh with the allow-list pointed at our fixture. Echoes stdout+stderr.
run_sched() { SCHEDULED_REPOS_FILE="$FIX" "$SCHED" "$@" 2>&1; }

# enable an onboarded slug → creates + lists it
rc=0; out="$(run_sched enable solar-income)" || rc=$?
assert_rc 0 "$rc" "enable onboarded slug exits 0"
assert_file_present "$FIX" "enable creates the allow-list file"
assert_eq "solar-income" "$(cat "$FIX")" "allow-list contains exactly the enabled slug"

# duplicate enable → no-op (still one line, message says already)
rc=0; out="$(run_sched enable solar-income)" || rc=$?
assert_rc 0 "$rc" "duplicate enable exits 0 (no-op)"
assert_contains "$out" "already" "duplicate enable reports it's already listed"
assert_eq "1" "$(grep -c . "$FIX")" "duplicate enable does not append a second line"

# enable a second onboarded slug → appended
rc=0; run_sched enable glyphosate-health >/dev/null || rc=$?
assert_rc 0 "$rc" "enable a second onboarded slug exits 0"
assert_eq "2" "$(grep -c . "$FIX")" "allow-list now has two slugs"

# enable a NON-onboarded slug → refused, naming the slug
rc=0; out="$(run_sched enable not-a-project)" || rc=$?
assert_ne 0 "$rc" "enable of a non-onboarded slug is refused (nonzero)"
assert_contains "$out" "not-a-project" "refusal names the offending slug" \
  "cmd_enable must reject a slug with no projects/<slug>.yml, naming it."
assert_eq "2" "$(grep -c . "$FIX")" "refused enable did not touch the allow-list"

# disable one → removed, the other remains, file still present
rc=0; run_sched disable solar-income >/dev/null || rc=$?
assert_rc 0 "$rc" "disable an entry exits 0"
assert_file_present "$FIX" "allow-list file still present with one entry remaining"
assert_eq "glyphosate-health" "$(cat "$FIX")" "the correct entry was removed"

# disable a slug not in the list → no-op
rc=0; out="$(run_sched disable solar-income)" || rc=$?
assert_rc 0 "$rc" "disable of an absent slug exits 0 (no-op)"
assert_contains "$out" "nothing to do" "disabling an absent slug reports nothing to do"

# disable the LAST entry → file removed (empty ⇒ all-live restored)
rc=0; out="$(run_sched disable glyphosate-health)" || rc=$?
assert_rc 0 "$rc" "disable the last entry exits 0"
assert_file_absent "$FIX" "emptying the allow-list removes the file (restores all-live)" \
  "cmd_disable must rm the file when the last slug is removed so the 'no allow-list' path is taken."
