#!/usr/bin/env bash
# tests/lib/assert.sh — shared assertion + reporting helpers for the two-tier suite.
# SOURCED by every test-*.sh (never executed). No external framework — pure bash,
# bash 3.2 clean (macOS ships 3.2, and CI runs on macos-latest to exercise it).
#
# Reporting contract (parsed by bin/test.sh's tally):
#   PASS: <msg>   an assertion held
#   SKIP: <msg>   a check was skipped (no gh/network/tmux) — never a failure
#   FAIL: <msg>   an assertion did NOT hold — prints a hint + exits 1 immediately
# A test file therefore exits nonzero the instant any assertion fails; the runner
# treats a nonzero OFFLINE test file as the failure signal. Online test files must
# only ever pass/skip (never call fail) so a missing-gh run stays green.
#
# Every test sources THIS first; it exports REPO_ROOT (this checkout's root) so a
# test can copy real bin/ scripts into a sandbox and reference briefs/, etc.

# Repo root = two levels up from tests/lib/ (tests/lib -> tests -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# The section a human should read when a check fails (kept identical to the old
# smoke test's anchor so muscle memory + docs still point somewhere real).
: "${TEST_HELP_SECTION:=Verify / test suite}"

pass() { printf 'PASS: %s\n' "$1"; }
skip() { printf 'SKIP: %s\n' "$1"; }
fail() {
  # $1 = what failed; $2 = what to do about it (optional).
  if [ -n "${2:-}" ]; then
    printf 'FAIL: %s\n      %s\n      See the README "%s" section.\n' \
      "$1" "$2" "$TEST_HELP_SECTION" >&2
  else
    printf 'FAIL: %s\n      See the README "%s" section.\n' \
      "$1" "$TEST_HELP_SECTION" >&2
  fi
  exit 1
}

# --- assertion helpers --------------------------------------------------------
# Each takes a trailing (desc, hint) pair used for PASS/FAIL messaging. They call
# pass on success and fail (which exits) on failure, so a test reads top-to-bottom
# with no manual rc bookkeeping.
#
# The three grep-based helpers below feed the haystack in on a HERESTRING, never
# `printf … | grep`. That is load-bearing, not style: `grep -q` exits the instant it
# matches, which closes the pipe, which hands the still-writing `printf` an EPIPE —
# and since every test file runs under `set -o pipefail`, that nonzero leftmost
# status becomes the pipeline's, so the `if` takes the *else* branch and reports
# FAIL for a needle that was actually found. It only fires when the haystack exceeds
# the pipe buffer and the needle sits far enough in for grep to still be reading, so
# it presents as a flaky test rather than a broken one — observed on a `pull_request`
# CI run failing `test-checker-rounds.sh` (`printf: write error: Broken pipe`, then
# FAIL) while the `push` run on the *same commit* passed. A herestring is a temp
# file, so no reader can ever close it early. Do not "simplify" these back to a pipe.

# assert_eq EXPECTED ACTUAL DESC [HINT]
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"
  else fail "$3 (expected '$1', got '$2')" "${4:-}"; fi
}

# assert_ne UNEXPECTED ACTUAL DESC [HINT]
assert_ne() {
  if [ "$1" != "$2" ]; then pass "$3"
  else fail "$3 (value was unexpectedly '$1')" "${4:-}"; fi
}

# assert_contains HAYSTACK NEEDLE DESC [HINT]   (fixed-string, not regex)
assert_contains() {
  if grep -qF -- "$2" <<<"$1"; then pass "$3"
  else fail "$3 (output did not contain '$2')" "${4:-}"; fi
}

# assert_not_contains HAYSTACK NEEDLE DESC [HINT]
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then fail "$3 (output unexpectedly contained '$2')" "${4:-}"
  else pass "$3"; fi
}

# assert_matches HAYSTACK ERE DESC [HINT]       (extended regex)
assert_matches() {
  if grep -qE -- "$2" <<<"$1"; then pass "$3"
  else fail "$3 (output did not match /$2/)" "${4:-}"; fi
}

# assert_rc EXPECTED_RC ACTUAL_RC DESC [HINT]
assert_rc() {
  if [ "$1" = "$2" ]; then pass "$3"
  else fail "$3 (expected exit $1, got $2)" "${4:-}"; fi
}

# assert_file_absent PATH DESC [HINT]
assert_file_absent() {
  if [ ! -e "$1" ]; then pass "$2"
  else fail "$2 (path exists: $1)" "${3:-}"; fi
}

# assert_file_present PATH DESC [HINT]
assert_file_present() {
  if [ -e "$1" ]; then pass "$2"
  else fail "$2 (path missing: $1)" "${3:-}"; fi
}
