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
# WORKTREE GUARD: `dr test` reaches this script through the ~/.local/bin/derailleur
# symlink into the INSTALL checkout, so $ORCH — and hence tests/ — is that checkout no
# matter where you stand. Run from inside a *different* derailleur checkout (a worktree)
# it would test the wrong tree while reporting a green tally for code that never ran
# (issue #50). So it refuses there and names `./bin/test.sh` instead; and every run,
# refused or not, opens by stating which tree it is testing.
#
# See the README "Verify / test suite" section.
set -uo pipefail   # NOT -e: the runner manages per-file exit codes itself.

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ORCH/tests"

# The original argv, as a string, so the refusal can echo back the exact corrective
# command. Built as a string rather than an array: expanding an empty array under
# `set -u` is fatal on bash 3.2 (see CLAUDE.md).
ARGS_STR=""
for a in "$@"; do ARGS_STR="$ARGS_STR $a"; done

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

# --- tree-under-test banner + worktree guard ----------------------------------
# count_tests DIR — echo how many test-*.sh files DIR holds (0 if it has none/absent).
count_tests() {
  local dir="$1" n=0 f
  shopt -s nullglob
  for f in "$dir"/test-*.sh; do n=$((n + 1)); done
  shopt -u nullglob
  printf '%s' "$n"
}

# is_derailleur_checkout DIR — true when DIR looks like a derailleur checkout. Kept as
# an explicit if/return (not a bare short-circuit) per CLAUDE.md.
is_derailleur_checkout() {
  if [ -f "$1/bin/test.sh" ] && [ -f "$1/bin/derailleur" ] && [ -d "$1/tests/offline" ]; then
    return 0
  fi
  return 1
}

banner="testing $ORCH ($(count_tests "$TESTS/offline") files in tests/offline"
if [ "$OFFLINE_ONLY" -eq 0 ]; then
  banner="$banner, $(count_tests "$TESTS/online") in tests/online"
fi
echo "$banner)"

# Refuse only when the cwd is inside a *different* derailleur checkout. A cwd that is
# unrelated to any derailleur checkout — another project's repo, $HOME, /tmp — or not a
# git work tree at all is the normal operator invocation and must keep working.
cwd_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cwd_top" ] && is_derailleur_checkout "$cwd_top"; then
  # Compare PHYSICAL paths so a symlinked route to the same tree doesn't read as a
  # different checkout.
  cwd_phys="$(cd "$cwd_top" && pwd -P)"
  orch_phys="$(cd "$ORCH" && pwd -P)"
  if [ "$cwd_phys" != "$orch_phys" ]; then
    {
      echo "test.sh: refusing to run — you are standing in a different derailleur checkout."
      echo "  you are in:        $cwd_phys"
      echo "  this would test:   $orch_phys"
      echo
      echo "\`dr test\` resolves through the ~/.local/bin symlink to the install checkout, so it"
      echo "would test that tree and report a green tally for the code you actually changed"
      echo "never having run. Run the suite from this tree instead:"
      echo
      echo "  ./bin/test.sh$ARGS_STR"
    } >&2
    exit 2
  fi
fi

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
