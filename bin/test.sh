#!/usr/bin/env bash
# test.sh — the derailleur test-suite runner (surfaced as `dr test`). Replaces the
# overgrown bin/smoke-test.sh with a growable two-tier suite under tests/.
#
# TWO TIERS:
#   * OFFLINE (tests/offline/) — deterministic, no network/`gh`. Always run and MUST
#     pass. This is the tier CI runs (`dr test --offline` on macos-latest / bash 3.2).
#   * ONLINE  (tests/online/)  — exercise real `gh` paths. Each SKIPs with a warning
#     when there's no network / gh auth, and never hard-fails the run when offline.
#
# The runner discovers test-*.sh files, runs each via `bash <file>` (so no +x /
# install.sh change is needed to add one), streams their PASS/SKIP/FAIL lines, tallies
# them, and exits nonzero IFF an OFFLINE test failed. Online SKIPs never make it exit
# nonzero. Individual test files are self-contained and can be run directly for
# debugging: `bash tests/offline/test-config-guard.sh`.
#
# Usage: test.sh [--offline]
#   (no args)   run the full suite (offline + online)
#   --offline   run only the offline tier (what CI uses)
#
# See the README "Verify / test suite" section.
set -uo pipefail   # NOT -e: the runner manages per-file exit codes itself.

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ORCH/tests"

OFFLINE_ONLY=0
for a in "$@"; do
  case "$a" in
    --offline) OFFLINE_ONLY=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "test.sh: unknown arg: $a (use --offline)" >&2; exit 2 ;;
  esac
done

[ -d "$TESTS" ] || { echo "test.sh: no tests/ dir at $TESTS" >&2; exit 2; }

# Tally + failure tracking. We count PASS/SKIP/FAIL lines across all files (for the
# summary) and separately track whether any OFFLINE file exited nonzero (the gate).
total_pass=0 total_skip=0 total_fail=0
offline_failed=0
declare -a FAILED_FILES

run_tier() {  # $1 = tier label (offline|online); $2 = dir
  local tier="$1" dir="$2" f rc out
  shopt -s nullglob
  local files=("$dir"/test-*.sh)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "  (no $tier tests found in $dir)"
    return 0
  fi
  for f in "${files[@]}"; do
    echo "── ${tier}/$(basename "$f") ──"
    rc=0
    # Capture combined output so we can tally, while streaming it to the terminal.
    out="$(bash "$f" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    # Tally by counting the contract lines the assert lib prints.
    local p s fl
    p="$(printf '%s\n' "$out" | grep -c '^PASS:')"
    s="$(printf '%s\n' "$out" | grep -c '^SKIP:')"
    fl="$(printf '%s\n' "$out" | grep -c '^FAIL:')"
    total_pass=$((total_pass + p))
    total_skip=$((total_skip + s))
    total_fail=$((total_fail + fl))
    if [ "$rc" -ne 0 ]; then
      if [ "$tier" = offline ]; then
        offline_failed=1
        FAILED_FILES+=("offline/$(basename "$f")")
      else
        # An online file exited nonzero WITHOUT the offline gate: treat it as a loud
        # warning (a real regression when gh is available), but per the tier contract
        # it does not gate the run. Online tests are written to skip, not fail.
        echo "  ⚠ online test exited nonzero ($rc) — not gating (see contract)."
        FAILED_FILES+=("online/$(basename "$f") [non-gating]")
      fi
    fi
    echo
  done
}

echo "=== derailleur test suite ==="
echo "== offline tier (deterministic; must pass) =="
run_tier offline "$TESTS/offline"

if [ "$OFFLINE_ONLY" -eq 0 ]; then
  echo "== online tier (real gh; SKIPs when offline) =="
  run_tier online "$TESTS/online"
else
  echo "== online tier skipped (--offline) =="
fi

echo "=========================================="
echo "totals: PASS=$total_pass  SKIP=$total_skip  FAIL=$total_fail"
if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
  echo "files with a nonzero exit:"
  printf '  - %s\n' "${FAILED_FILES[@]}"
fi

if [ "$offline_failed" -ne 0 ]; then
  echo "RESULT: FAIL (an offline test failed)"
  exit 1
fi
echo "RESULT: PASS (all offline tests passed)"
exit 0
