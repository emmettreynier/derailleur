#!/usr/bin/env bash
# tests/offline/test-manifest-parser-conformance.sh — the deny-hook and the launchers
# must read a project manifest THE SAME WAY (issue #76).
#
# WHY THIS EXISTS. `host/hooks/raw-data-guard.py` (Safety Layer 2) and the launchers'
# `yml_list()` are two implementations of the same manifest list grammar, in two
# languages, reading the same file. When they disagree the hook silently drops a
# declared write-protected prefix — no error, no warning, just a protection control
# that no longer does what its manifest says. That is exactly what happened: the hook's
# pre-#76 block matcher `((?:[ \t]+-.*\n?)+)` accepted only CONSECUTIVE entry lines, so
# projects/california-pesticides.yml's `derived/` — which follows a continuation
# comment — was dropped from `raw_paths`. (No live exposure: that manifest's
# `raw_resolved` blankets the whole data tree. A latent defect in a control, not a hole.)
#
# WHAT IT ASSERTS, in four layers:
#   1. structural — the two launchers still carry one identical `yml_list()`, and the
#      test can still reach both real parsers (a restructure fails loud, never silent).
#   2. absolute   — the hook returns the EXPECTED list for each grammar shape. Agreement
#      alone is not enough: two identically-broken parsers agree.
#   3. conformance— hook == launcher for every top-level key, over the fixtures AND over
#      every real manifest in the install checkout's projects/.
#   4. outcome    — with `raw_resolved` NEUTRALISED so the blanket prefix cannot mask the
#      result, a Write under a `raw_paths` entry that follows a comment line is DENIED.
#
# Neither parser is reimplemented here — see tests/lib/manifest-parsers.py for how each
# real one is reached.
#
# Offline, hermetic, no dispatch: the fixtures name only /nonexistent paths, the deny
# check runs in an mktemp sandbox, and the real-manifest sweep only READS projects/*.yml.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/sandbox.sh"

HELPER="$REPO_ROOT/tests/lib/manifest-parsers.py"
HOOK_PY="$REPO_ROOT/host/hooks/raw-data-guard.py"
WORKER="$REPO_ROOT/bin/launch-worker.sh"
CHECKER="$REPO_ROOT/bin/launch-checker.sh"
FIXTURES="$REPO_ROOT/tests/fixtures/manifests"

for f in "$HELPER" "$HOOK_PY" "$WORKER" "$CHECKER"; do
  [ -f "$f" ] || fail "missing $f" "The file under test is gone — this test cannot run."
done

# hook_list MANIFEST KEY — the hook's parse, as a '|'-terminated string so an ordered
# list can be compared with assert_eq (bash 3.2 has no array comparison).
hook_list() { python3 "$HELPER" hook-list "$HOOK_PY" "$1" "$2" | tr '\n' '|'; }

echo "--- 1. structural: both launchers carry one identical yml_list() ---"
w_src="$(python3 "$HELPER" extract "$WORKER")"; w_rc=$?
assert_rc 0 "$w_rc" "yml_list() python program extracted from launch-worker.sh" \
  "The launcher's parser was restructured; update tests/lib/manifest-parsers.py."
c_src="$(python3 "$HELPER" extract "$CHECKER")"; c_rc=$?
assert_rc 0 "$c_rc" "yml_list() python program extracted from launch-checker.sh" \
  "The launcher's parser was restructured; update tests/lib/manifest-parsers.py."
assert_eq "$w_src" "$c_src" "launch-worker.sh and launch-checker.sh yml_list() are identical" \
  "The two launchers' duplicated parsers have drifted — re-sync them."
assert_contains "$w_src" "re.search" "the extracted launcher program is the regex parser (not some other heredoc)" \
  "manifest-parsers.py extracted the wrong heredoc."

echo
echo "--- 2. absolute: the hook returns the expected list for each grammar shape ---"
assert_eq "raw/|derived/|" "$(hook_list "$FIXTURES/continuation-comment.yml" raw_paths)" \
  "continuation comment mid-block: entries after it survive" \
  "host/hooks/raw-data-guard.py list_items() truncates at a continuation comment (issue #76)."
assert_eq "raw/|derived/|reference/|" "$(hook_list "$FIXTURES/whole-line-comment.yml" raw_paths)" \
  "whole-line + indented comment mid-block: entries after them survive" \
  "list_items() must skip comment lines, not stop at them."
assert_eq "raw/|derived/|" "$(hook_list "$FIXTURES/blank-line.yml" raw_paths)" \
  "blank line mid-block: entries after it survive" \
  "list_items() must tolerate a blank line inside a block."
assert_eq "output/|" "$(hook_list "$FIXTURES/blank-line.yml" output_paths)" \
  "blank line directly after the key: the block is still read"
assert_eq "raw/|derived/|reference/|" "$(hook_list "$FIXTURES/trailing-comment.yml" raw_paths)" \
  "trailing '#' comments on entries are stripped, entries kept" \
  "list_items() must strip a trailing comment, with or without a space before the hash."
assert_eq "06 Raw_data/|single quoted/|quoted with comment/|unquoted/|" \
  "$(hook_list "$FIXTURES/quoted-entries.yml" raw_paths)" \
  "quoted entries are unquoted (incl. a path with spaces)" \
  "list_items() must strip matching double/single quotes."
assert_eq "raw/|derived/|" "$(hook_list "$FIXTURES/no-trailing-newline.yml" raw_paths)" \
  "final entry at EOF with NO trailing newline is read" \
  "list_items()'s block matcher needs the optional no-newline tail (issue #74, W1)."

echo
echo "--- 2b. end of block: a widened matcher must NOT run on into the next key ---"
bb="$FIXTURES/block-boundary.yml"
assert_eq "raw/|" "$(hook_list "$bb" raw_paths)" \
  "raw_paths stops at the next non-indented key" \
  "The block matcher is running past the end of its block — it must stop at a 'key:' line."
assert_not_contains "$(hook_list "$bb" raw_paths)" "other-input" \
  "raw_paths did not absorb the following key's entries"
assert_not_contains "$(hook_list "$bb" raw_paths)" "output/" \
  "raw_paths did not absorb a later key's entries"
assert_eq "" "$(hook_list "$bb" critical_paths)" \
  "an EMPTY list directly before a populated one reads as empty" \
  "The block matcher swallowed the next key's entries into an empty block."
assert_eq "/nonexistent/block-boundary/other-input|" "$(hook_list "$bb" extra_read_resolved)" \
  "the key after an empty list still parses its own entries"
assert_eq "output/|" "$(hook_list "$bb" output_paths)" \
  "a block separated by a blank line from the previous key parses alone"

echo
echo "--- 3a. conformance over the fixtures: hook == launcher, every key ---"
shopt -s nullglob
fixtures=("$FIXTURES"/*.yml)
shopt -u nullglob
[ "${#fixtures[@]}" -gt 0 ] \
  || fail "no fixture manifests found in $FIXTURES" \
          "tests/fixtures/manifests/*.yml is empty — the conformance sweep would pass vacuously."
echo "    fixtures swept: ${#fixtures[@]} ($FIXTURES)"
for fx in "${fixtures[@]}"; do
  out="$(python3 "$HELPER" compare "$WORKER" "$HOOK_PY" "$fx" 2>&1)"; rc=$?
  assert_rc 0 "$rc" "hook == launcher for every key in $(basename "$fx") [$out]" \
    "The deny-hook and the launcher parse this manifest differently — a declared write-protected prefix may be silently dropped."
done

echo
echo "--- 3b. conformance over the REAL manifests in the install checkout ---"
# projects/*.yml is gitignored, so a dispatched worker's WORKTREE holds only .gitkeep and
# a glob of ./projects would sweep zero manifests and pass without testing anything —
# the exact failure mode this test exists to close (issue #76). git-common-dir points at
# the PRIMARY checkout's .git from a linked worktree, and at ./.git in CI.
PROJECTS=""
if common_dir="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null)"; then
  PROJECTS="$(cd "$REPO_ROOT" && cd "$common_dir/.." && pwd)/projects"
fi
if [ -z "$PROJECTS" ]; then
  skip "not a git work tree — cannot resolve the install checkout's projects/ (swept 0 real manifests)"
else
  shopt -s nullglob
  reals=("$PROJECTS"/*.yml)     # *.yml only: skips strays like *.yml.bak-preextraread
  shopt -u nullglob
  echo "    real manifests swept: ${#reals[@]} ($PROJECTS)"
  if [ "${#reals[@]}" -eq 0 ]; then
    skip "0 real manifests in $PROJECTS — the real-manifest sweep asserted NOTHING (expected in CI, where projects/ is gitignored and empty; NOT expected on an operator's machine)"
  else
    for rm_ in "${reals[@]}"; do
      out="$(python3 "$HELPER" compare "$WORKER" "$HOOK_PY" "$rm_" 2>&1)"; rc=$?
      assert_rc 0 "$rc" "hook == launcher for every key in $(basename "$rm_") [$out]" \
        "The deny-hook and the launcher parse this REAL manifest differently — it is protecting fewer paths than it declares."
    done
    # The regression that motivated the issue, asserted on the real file by invoking the
    # hook (not by inspection). SKIPped, loudly, when that project isn't onboarded here.
    cap="$PROJECTS/california-pesticides.yml"
    if [ -f "$cap" ]; then
      assert_eq "raw/|derived/|" "$(hook_list "$cap" raw_paths)" \
        "real projects/california-pesticides.yml raw_paths reads as ['raw/', 'derived/']" \
        "The continuation comment on line 57 is truncating the block again (issue #76)."
    else
      skip "no $cap on this machine — the named-regression check did not run"
    fi
  fi
fi

echo
echo "--- 4. outcome: raw_paths alone must deny, with raw_resolved neutralised ---"
# Testing california-pesticides' derived/ directly would be VACUOUS: its raw_resolved
# blankets the whole data tree, so that write is denied with or without the fix. This
# fixture points raw_resolved at an unrelated sibling tree, so the ONLY thing that can
# protect data/derived is the raw_paths entry sitting after a comment line.
sb="$(sandbox_tmp)"
mkdir -p "$sb/data/raw" "$sb/data/derived" "$sb/data/results" "$sb/elsewhere"
cat >"$sb/neutralised.yml" <<YML
repo: example/neutralised
data_root: $sb/data
# raw_resolved NEUTRALISED: a real, present key pointed at a tree that does NOT contain
# data/derived, so it cannot mask the raw_paths contribution under test.
raw_resolved: $sb/elsewhere
raw_paths:
  - raw/         # a comment that continues
                 # onto its own line — the pre-#76 parser stopped reading here
  - derived/
YML

# deny_verdict PATH — 'deny' if the hook blocks a Write to PATH, else 'allow'.
deny_verdict() {
  local out
  out="$(ORCH_MANIFEST="$sb/neutralised.yml" python3 "$HOOK_PY" \
          <<<"{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$1\"}}")"
  case "$out" in
    *'"permissionDecision": "deny"'*) printf 'deny' ;;
    *) printf 'allow' ;;
  esac
}

assert_eq "deny" "$(deny_verdict "$sb/elsewhere/scratch.txt")" \
  "control: raw_resolved still protects its own tree (the key is present, not deleted)"
assert_eq "deny" "$(deny_verdict "$sb/data/raw/scratch.txt")" \
  "control: the raw_paths entry BEFORE the comment is protected"
assert_eq "deny" "$(deny_verdict "$sb/data/derived/scratch.txt")" \
  "the raw_paths entry AFTER the comment is protected — raw_paths alone, no blanket" \
  "This is the issue-#76 regression: list_items() dropped the entry, so the hook allowed a write the manifest declares read-only."
assert_eq "allow" "$(deny_verdict "$sb/data/results/scratch.txt")" \
  "a path the manifest does NOT declare stays writable (the fix did not over-protect)"

echo
echo "conformance: done."
