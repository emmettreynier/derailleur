#!/usr/bin/env bash
# test-board-digest-buckets.sh (OFFLINE) — board-digest.sh's open-PR bucketing, run
# against fixture board + PR JSON through a `gh` shim. No network, no real conf, no
# real board: every case builds its own throwaway ORCH sandbox.
#
# The bug this pins (issue #69): a READY (un-drafted) PR whose closing issue carries
# `resume` used to match neither the draft branch (worker's court) nor the
# checked-pass branch (merge gate) nor the checker's court — it hit a bare `pass` and
# vanished from the digest entirely, so no worker, no checker and no operator ever saw
# it again. It now routes to the worker's court under the SAME guards as its draft
# sibling (no live worker, no needs-input/hold/blocked), and a worker's-court PR whose
# closing-issue board row can't be resolved is reported with a ⚠ instead of dropped.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 \
  || { skip "python3 not installed — skipping board-digest bucketing"; exit 0; }

SLUG="fixture"
REPO="test-operator/$SLUG"          # PR_OWNER in write_filled_conf is test-operator
REPO_URL="https://github.com/$REPO"
PR_URL="$REPO_URL/pull/11"

# run_digest — build a sandbox for one case and echo the digest it produces.
#   $1 isDraft            true|false
#   $2 issue labels       comma-separated (e.g. "resume" / "resume,hold" / "")
#   $3 ledger pid         a live pid to fake an in-flight worker, or "" for none
#   $4 board issue number the number the fixture board row carries (the PR always
#                         closes #3, so passing anything else models "issue not on
#                         the board")
#   $5 board status        the fixture row's Status field (default "In Progress")
# Every case's gh shim logs its calls to CALLS_LOG — a path in the sandbox ROOT, not
# in the per-case sandbox, because run_digest is called in a $(…) subshell and any
# variable it sets (the sandbox path included) dies with that subshell.
run_digest() {
  local draft="$1" labels="$2" pid="$3" board_num="$4" status="${5:-In Progress}" sb shim
  sb="$(new_sandbox)"
  sandbox_copy_script "$sb" board-digest
  cp "$REPO_ROOT/bin/config-common.sh" "$sb/bin/config-common.sh"
  write_filled_conf "$sb"
  write_project_manifest "$sb" "$SLUG" "$REPO"

  # --- fixture JSON the shim serves ------------------------------------------
  LABELS="$labels" BOARD_NUM="$board_num" BOARD_STATUS="$status" \
    REPO_URL="$REPO_URL" python3 - "$sb/board.json" <<'PY'
import json, os, sys
labels = [l for l in os.environ["LABELS"].split(",") if l]
json.dump({"items": [{
    "title": "Fixture issue", "status": os.environ["BOARD_STATUS"], "project": "Test",
    "repository": os.environ["REPO_URL"], "labels": labels,
    "content": {"type": "Issue", "number": int(os.environ["BOARD_NUM"]),
                "title": "Fixture issue",
                "body": "One-line lead.\n\n- [ ] a criterion\n"},
}]}, open(sys.argv[1], "w"))
PY
  DRAFT="$draft" PR_URL="$PR_URL" python3 - "$sb/prs.json" <<'PY'
import json, os, sys
json.dump([{
    "number": 11, "title": "Fixture PR", "url": os.environ["PR_URL"],
    "isDraft": os.environ["DRAFT"] == "true", "reviewDecision": "",
    "headRefName": "issue-3", "closingIssuesReferences": [{"number": 3}],
    "labels": [],
}], open(sys.argv[1], "w"))
PY

  if [ -n "$pid" ]; then
    printf -- '- #3 | %s | issue-3 | %s/logs/w.log | pid %s | dispatched 2026-08-19T00:00:00Z | status dispatched\n' \
      "$REPO" "$sb" "$pid" > "$sb/ledger.md"
  fi

  # --- gh shim: answers only the three calls the digest makes, and logs each one
  # so the "no new network calls" criterion is checkable rather than asserted.
  shim="$(sandbox_tmp)"
  cat >"$shim/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "project item-list") cat "$GH_BOARD" ;;
  "search issues")     echo '[]' ;;
  "pr list")           cat "$GH_PRS" ;;
  "issue view")        echo '{"title":"off-board issue","state":"OPEN"}' ;;
  *) echo "gh shim: unexpected call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$shim/gh"
  # A real tmux would probe the operator's live sessions; keep the case hermetic.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/tmux"; chmod +x "$shim/tmux"

  : >"$CALLS_LOG"
  PATH="$shim:$PATH" GH_BOARD="$sb/board.json" GH_PRS="$sb/prs.json" \
    GH_CALLS="$CALLS_LOG" "$sb/bin/board-digest.sh"
}

# block SECTION_HEADER — the digest lines under one bold/### header, up to the next one.
block() {  # $1 = digest text, $2 = header substring
  awk -v pat="$2" '
    index($0, pat) { on = 1; next }
    on && (/^\*\*/ || /^## /) { exit }
    on { print }
  ' <<<"$1"
}

count_of() {  # $1 = haystack, $2 = fixed needle -> occurrence count
  grep -cF -- "$2" <<<"$1" || true
}

CALLS_LOG="$_SANDBOX_ROOT/gh-calls.log"

gh_calls() { wc -l <"$CALLS_LOG" | tr -d ' '; }

RESUME_HDR="**resume — revisions to re-dispatch"
CHECK_HDR="**Ready PRs awaiting checker"
NI_HDR="**needs-input ("
UNROUTED_HDR="closing issue not on the board"
ROW="$SLUG#3 — Fixture issue"

# --- (a) ready + resume + no live worker -> worker's court, exactly once ------
out="$(run_digest false resume "" 3)"
assert_contains "$(block "$out" "$RESUME_HDR")" "$ROW" \
  "ready PR + resume on its issue lands in the resume bucket (issue #69)" \
  "board-digest.sh's classification branch dropped it again — see the ready+resume arm."
assert_eq 1 "$(count_of "$(block "$out" "$RESUME_HDR")" "$ROW")" \
  "ready + resume appears exactly once in the resume bucket"
assert_contains "$(block "$out" "$CHECK_HDR")" "- none" \
  "ready + resume is NOT also sent to the checker's court"
assert_eq 0 "$(count_of "$out" "$PR_URL")" \
  "the routed PR is represented by its issue row only (no second bucket)"
assert_contains "$out" "## Dispatch candidates — worker's court (1)" \
  "the candidate count includes the routed ready+resume PR"
assert_eq 3 "$(gh_calls)" \
  "the digest makes 3 gh calls (board + closed-issue search + one pr list)" \
  "Routing is a classification change over data already fetched — it must add no query."

# --- (b) ready + resume + a live worker -> in-flight, not a candidate ---------
out="$(run_digest false resume "$$" 3)"
assert_contains "$(block "$out" "$RESUME_HDR")" "- none" \
  "a live worker suppresses ready + resume from the resume bucket"
assert_contains "$(block "$out" "$CHECK_HDR")" "- none" \
  "a live worker's ready + resume PR is not sent to the checker either"
assert_contains "$out" "⚙ in-flight" \
  "the live worker is still visible on its issue row"
assert_eq 3 "$(gh_calls)" \
  "the live-worker case makes the same 3 gh calls"

# --- (c) ready + resume + hold / blocked -> parked, no dispatch bucket --------
for park in hold blocked; do
  out="$(run_digest false "resume,$park" "" 3)"
  assert_contains "$(block "$out" "$RESUME_HDR")" "- none" \
    "$park parks ready + resume out of the worker's court (same guards as a draft)"
  assert_contains "$(block "$out" "$CHECK_HDR")" "- none" \
    "$park keeps ready + resume out of the checker's court too"
done

# --- (d) ready + needs-input -> operator's court only (the :359 half kept) ----
out="$(run_digest false needs-input "" 3)"
assert_contains "$(block "$out" "$RESUME_HDR")" "- none" \
  "ready + needs-input is NOT duplicated into the dispatch candidates"
assert_contains "$(block "$out" "$NI_HDR")" "$ROW" \
  "ready + needs-input is still surfaced in the operator's needs-input section"
assert_contains "$(block "$out" "$CHECK_HDR")" "- none" \
  "ready + needs-input is not sent to the checker"

# --- (e) draft + resume -> unchanged (regression net) ------------------------
out="$(run_digest true resume "" 3)"
assert_contains "$(block "$out" "$RESUME_HDR")" "$ROW" \
  "draft + resume still lands in the resume bucket (unchanged)"
assert_eq 1 "$(count_of "$(block "$out" "$RESUME_HDR")" "$ROW")" \
  "draft + resume appears exactly once"
assert_eq 0 "$(count_of "$out" "$PR_URL")" \
  "draft + resume is not also listed as a PR line elsewhere"
assert_eq 3 "$(gh_calls)" \
  "the draft case makes the same 3 gh calls as the ready one"

# --- (f) worker's-court PR whose closing issue has no board row -> ⚠ ---------
# Board carries an unrelated Backlog row (#4); the PR closes #3, so pr_issue_row()
# can't resolve a row for it. Note the
# routing labels are read from those same rows, so a READY PR in this state has no
# visible `resume` at all and stays in the checker's court — the reachable instance of
# "routed but unroutable" is the structural draft branch, and that is what used to be
# dropped in silence.
out="$(run_digest true "" "" 4 Backlog)"
assert_contains "$out" "$UNROUTED_HDR" \
  "a worker's-court PR with no board row for its closing issue is reported (issue #69)" \
  "It must never be silently dropped — the resume-bucket loop skips it by construction."
assert_contains "$(block "$out" "$UNROUTED_HDR")" "$SLUG#11" \
  "the ⚠ line names the PR"
assert_contains "$(block "$out" "$RESUME_HDR")" "- none" \
  "the unroutable PR is not faked into the resume bucket"
assert_contains "$out" "## Dispatch candidates — worker's court (0)" \
  "the ⚠ line is reported, not counted as a dispatchable candidate"
assert_eq 1 "$(count_of "$out" "$PR_URL")" \
  "the unroutable PR is listed in exactly one place"
