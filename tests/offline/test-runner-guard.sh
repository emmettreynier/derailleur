#!/usr/bin/env bash
# test-runner-guard.sh (offline) — bin/test.sh's worktree guard + tree-under-test
# banner (issue #50). `dr test` resolves through the ~/.local/bin symlink to the
# INSTALL checkout, so run from a worktree it used to test the *primary* checkout and
# report a green tally for code that never ran. The runner must now refuse that case,
# name both trees and `./bin/test.sh`, and open every run by saying which tree it tests.
#
# Everything runs against throwaway fake checkouts under the sandbox root — no real
# checkout, conf, or project data is touched, and no real suite is executed.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

# mk_checkout DIR — build a minimal fake derailleur checkout: the real bin/test.sh
# under test, the bin/derailleur + tests/offline/ markers the guard identifies a
# checkout by, and two trivial offline tests so the banner has a count to report.
mk_checkout() {
  local d="$1" i
  mkdir -p "$d/bin" "$d/tests/offline" "$d/tests/online"
  cp "$REPO_ROOT/bin/test.sh" "$d/bin/test.sh"
  : >"$d/bin/derailleur"
  for i in one two; do
    printf 'echo "PASS: fake %s"\n' "$i" >"$d/tests/offline/test-$i.sh"
  done
  git init -q "$d"
}

phys() { (cd "$1" && pwd -P); }

A="$(sandbox_tmp)/checkout-a"; mk_checkout "$A"
B="$(sandbox_tmp)/checkout-b"; mk_checkout "$B"
# Normalize the logical paths the way the script's own `cd … && pwd` does (TMPDIR can
# carry a trailing slash, which would otherwise make the banner string compare unequal).
A="$(cd "$A" && pwd)"
B="$(cd "$B" && pwd)"
A_PHYS="$(phys "$A")"
B_PHYS="$(phys "$B")"

# (a) cwd = checkout B, script = checkout A → refuse, nonzero, name both + the fix.
rc=0
out="$(cd "$B" && bash "$A/bin/test.sh" --offline 2>&1)" || rc=$?
assert_ne 0 "$rc" "cwd in a different derailleur checkout: exits nonzero" \
  "bin/test.sh must refuse (not silently test the other tree) — see the worktree guard."
assert_contains "$out" "refusing to run" "refusal says it is refusing to run"
assert_contains "$out" "$B_PHYS" "refusal names the tree you are standing in" \
  "The message must print the cwd's git top level, physically resolved."
assert_contains "$out" "$A_PHYS" "refusal names the tree the script would have tested" \
  "The message must print the script's own \$ORCH, physically resolved."
assert_contains "$out" "./bin/test.sh --offline" "refusal gives the corrective command with the original args" \
  "The refusal forwards argv so the operator can paste the fix verbatim."
assert_not_contains "$out" "RESULT: PASS" "a refused run never reports a passing suite" \
  "The whole point of the guard is that a wrong-tree run must not end green."

# (b) cwd = an unrelated git repo (not a derailleur checkout) → runs.
OTHER="$(sandbox_tmp)/other-project"
mkdir -p "$OTHER"; git init -q "$OTHER"
rc=0
out="$(cd "$OTHER" && bash "$A/bin/test.sh" --offline 2>&1)" || rc=$?
assert_rc 0 "$rc" "cwd in an unrelated git repo: runs normally" \
  "The guard must only fire inside another *derailleur* checkout."
assert_contains "$out" "RESULT: PASS" "unrelated-cwd run completes the suite"
assert_contains "$out" "testing $A" "unrelated-cwd run banners the tree under test"

# (c) cwd top level == the script's own tree → runs (dr test from the primary
#     checkout, or ./bin/test.sh from inside a worktree).
rc=0
out="$(cd "$A" && bash "$A/bin/test.sh" --offline 2>&1)" || rc=$?
assert_rc 0 "$rc" "cwd top level == the script's own checkout: runs normally" \
  "Same tree is the correct invocation and must never be refused."
assert_contains "$out" "RESULT: PASS" "same-tree run completes the suite"

#     …and via a symlinked route to that same tree, which must not read as different.
LINK="$(sandbox_tmp)/link-to-a"
ln -s "$A" "$LINK"
rc=0
out="$(cd "$LINK" && bash "$LINK/bin/test.sh" --offline 2>&1)" || rc=$?
assert_rc 0 "$rc" "same tree reached through a symlink: runs normally" \
  "Both paths are compared physically (pwd -P) so a symlink is not a different tree."

# (d) cwd not in a git work tree at all → runs (treated as unrelated, not an error).
NOGIT="$(sandbox_tmp)"
if (cd "$NOGIT" && git rev-parse --show-toplevel >/dev/null 2>&1); then
  skip "sandbox root is itself inside a git work tree — cannot test the no-git cwd case"
else
  rc=0
  out="$(cd "$NOGIT" && bash "$A/bin/test.sh" --offline 2>&1)" || rc=$?
  assert_rc 0 "$rc" "cwd not a git work tree: runs normally" \
    "A failing \`git rev-parse\` means 'unrelated cwd', not an error."
  assert_contains "$out" "RESULT: PASS" "non-git-cwd run completes the suite"
fi

# (e) the banner: first line, names the tree, counts the discovered files — and is
#     present on a refused run too (the half that kills the silent green).
#     First lines are taken by parameter expansion, not `| head -1`: under
#     `set -o pipefail` a head that closes the pipe early SIGPIPEs the runner and
#     aborts the test file.
head1() { printf '%s' "${1%%$'\n'*}"; }

out="$(cd "$NOGIT" && bash "$A/bin/test.sh" --offline 2>&1 || true)"
assert_eq "testing $A (2 files in tests/offline)" "$(head1 "$out")" \
  "banner is the first line and reports tree + discovered offline file count" \
  "Every run must open by stating which tree it tests and how many files it found."
out="$(cd "$NOGIT" && bash "$A/bin/test.sh" 2>&1 || true)"
assert_contains "$(head1 "$out")" "in tests/online" "full-suite banner also counts the online tier"
out="$(cd "$B" && bash "$A/bin/test.sh" --offline 2>&1 || true)"
assert_eq "testing $A (2 files in tests/offline)" "$(head1 "$out")" \
  "banner is printed on a refused run too" \
  "The banner must precede the refusal so even a bypassed guard states the tree."
