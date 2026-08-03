#!/usr/bin/env bash
# test-assert-lib.sh (offline) — the assertion helpers themselves.
#
# The regression this file exists to hold: the three grep-based helpers must NOT feed
# the haystack in through a pipe (`printf '%s' "$hay" | grep -q …`). `grep -q` exits
# the instant it matches, closing the pipe and handing the still-writing `printf` an
# EPIPE; every test file runs under `set -o pipefail`, so that nonzero leftmost status
# becomes the pipeline's and the `if` takes the *else* branch — reporting FAIL for a
# needle that was found. It only fires when the haystack exceeds the pipe buffer and
# the needle sits far enough in for grep to still be reading, so it surfaces as a
# FLAKY test: observed as a `pull_request` CI run failing test-checker-rounds.sh with
# `printf: write error: Broken pipe` while the `push` run on the SAME commit passed.
#
# A lying test run is the exact failure mode this suite is supposed to prevent, so the
# helper that decides pass-vs-fail gets its own net.
#
# Hermetic: pure in-memory strings. No `gh`, no network, nothing dispatched.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"

ASSERT_LIB="$TEST_DIR/../lib/assert.sh"
assert_file_present "$ASSERT_LIB" "tests/lib/assert.sh present" \
  "The shared assertion helpers are missing from tests/lib/."

# --- the structural guard: no printf-into-grep in the helpers -------------------
# Source-level, because the runtime symptom is a race that cannot be triggered on
# demand (it depends on the pipe buffer size, which varies by host).
LIB_SRC="$(cat "$ASSERT_LIB")"
assert_not_contains "$LIB_SRC" '| grep -q' \
  "no assertion helper pipes its haystack into grep -q" \
  "grep -q closes the pipe on match -> printf EPIPE -> pipefail turns a MATCH into a FAIL. Use a <<< herestring."

# --- and the behaviour those helpers must have ----------------------------------
# A haystack comfortably larger than any pipe buffer (~1 MB), with the needle EARLY so
# grep matches and stops long before the whole thing could be written. Under the old
# piped implementation this is precisely the shape that produced a false FAIL.
BIG_LINE="$(printf 'x%.0s' $(seq 1 200))"
BIG=""
for _ in $(seq 1 5000); do BIG="$BIG$BIG_LINE"$'\n'; done
HAY="needle-at-the-very-start"$'\n'"$BIG"
assert_contains "$HAY" "needle-at-the-very-start" \
  "assert_contains finds an early needle in a haystack larger than the pipe buffer" \
  "This is the false-FAIL shape: grep matches on line 1 and exits while the writer is still going."
assert_matches "$HAY" '^needle-at-the-very-start$' \
  "assert_matches finds an early match in a haystack larger than the pipe buffer" \
  "Same SIGPIPE hazard as assert_contains — assert_matches must be pipe-free too."
assert_not_contains "$HAY" "this-string-is-definitely-absent" \
  "assert_not_contains still reports absence correctly on a large haystack" \
  "The no-pipe rewrite must not change the negative case."

# The ordinary small-string cases, so the rewrite is pinned on both sides.
assert_contains "alpha beta gamma" "beta" \
  "assert_contains matches a substring" \
  "Basic positive case for the herestring form."
assert_contains "$(printf 'one\ntwo\nthree')" "two" \
  "assert_contains matches across a multi-line haystack" \
  "A herestring must not collapse or truncate embedded newlines."
assert_not_contains "alpha beta gamma" "delta" \
  "assert_not_contains reports an absent substring" \
  "Basic negative case for the herestring form."
assert_contains 'literal $dollar and *star*' '$dollar and *star*' \
  "assert_contains treats the needle as a FIXED string, not a pattern" \
  "grep -F is what lets tests assert on unexpanded shell source like '**Checker incomplete: \$st**'."
assert_matches "abc123" '^[a-c]+[0-9]+$' \
  "assert_matches applies an extended regex" \
  "assert_matches must stay regex-based (grep -E) after the herestring rewrite."
