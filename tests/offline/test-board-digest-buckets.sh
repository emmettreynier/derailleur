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
#
# Cases (i)–(l) pin the STALE-PASS bucket (issue #83): a ready PR whose issue carries
# `checked-pass` is only merge-ready if a checker has actually seen its CURRENT head.
# Head commit newer than the newest `**Checker verdict:` comment — or no such comment at
# all — means the label is left over from an earlier round, and the PR must NOT be
# offered to the operator as reviewed.
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
#   $6 extra body lines   appended to the fixture issue BODY (used to plant a
#                         `- [ ] (directive)` acceptance criterion — issue #77)
#   $7 head commit date   ISO8601; empty (default) omits `commits`/`comments` from the
#                         fixture PR entirely, which is the "unknowable" case the
#                         stale-pass check must abstain on (issue #83)
#   $8 verdict comment    ISO8601 createdAt for a `**Checker verdict:` PR comment;
#                         empty with $7 set models a checked-pass PR that carries no
#                         verdict comment at all
# Every case's gh shim logs its calls to CALLS_LOG — a path in the sandbox ROOT, not
# in the per-case sandbox, because run_digest is called in a $(…) subshell and any
# variable it sets (the sandbox path included) dies with that subshell.
run_digest() {
  local draft="$1" labels="$2" pid="$3" board_num="$4" status="${5:-In Progress}" \
        extra_body="${6:-}" head_date="${7:-}" verdict_date="${8:-}" body sb shim
  body="$(printf 'One-line lead.\n\n- [ ] a criterion\n%s' "$extra_body")"
  sb="$(new_sandbox)"
  sandbox_copy_script "$sb" board-digest
  cp "$REPO_ROOT/bin/config-common.sh" "$sb/bin/config-common.sh"
  write_filled_conf "$sb"
  write_project_manifest "$sb" "$SLUG" "$REPO"

  # --- fixture JSON the shim serves ------------------------------------------
  LABELS="$labels" BOARD_NUM="$board_num" BOARD_STATUS="$status" BODY="$body" \
    REPO_URL="$REPO_URL" python3 - "$sb/board.json" <<'PY'
import json, os, sys
labels = [l for l in os.environ["LABELS"].split(",") if l]
json.dump({"items": [{
    "title": "Fixture issue", "status": os.environ["BOARD_STATUS"], "project": "Test",
    "repository": os.environ["REPO_URL"], "labels": labels,
    "content": {"type": "Issue", "number": int(os.environ["BOARD_NUM"]),
                "title": "Fixture issue", "body": os.environ["BODY"]},
}]}, open(sys.argv[1], "w"))
PY
  DRAFT="$draft" PR_URL="$PR_URL" HEAD_DATE="$head_date" VERDICT_DATE="$verdict_date" \
    python3 - "$sb/prs.json" <<'PY'
import json, os, sys
pr = {
    "number": 11, "title": "Fixture PR", "url": os.environ["PR_URL"],
    "isDraft": os.environ["DRAFT"] == "true", "reviewDecision": "",
    "headRefName": "issue-3", "closingIssuesReferences": [{"number": 3}],
    "labels": [],
}
# `commits`/`comments` only when the case asks for them: their ABSENCE is itself a
# fixture state (the stale-pass check must abstain rather than condemn — issue #83),
# and every pre-#83 case here relies on the digest behaving exactly as it did before.
head = os.environ.get("HEAD_DATE") or ""
if head:
    pr["commits"] = [{"committedDate": head}]
    vd = os.environ.get("VERDICT_DATE") or ""
    pr["comments"] = ([{"createdAt": vd, "body": "**Checker verdict: pass**\n\ndetail"}]
                      if vd else [])
json.dump([pr], open(sys.argv[1], "w"))
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
# The ✍ marker board-digest.sh appends to a resume row whose issue body still carries an
# unchecked `- [ ] (directive)` acceptance criterion (issue #77).
DIRECTIVE_MARK="✍ operator-directive pending"
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
assert_not_contains "$(block "$out" "$RESUME_HDR")" "$DIRECTIVE_MARK" \
  "a plain checker-bounce resume carries NO operator-directive marker" \
  "The marker must distinguish an operator extension from a checker bounce, not tag every resume row (#77)."

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

# --- (g) resume whose issue body carries an UNCHECKED (directive) criterion ---------
# An operator directive (issue #77) is mirrored into the issue BODY as
# `- [ ] (directive) …`, and the body is ALREADY in the board JSON — so the digest can
# distinguish "handed back because the operator extended the scope" from "handed back
# because the checker found something" for free. The gh-call assertion is the point: the
# marker must be derived, never fetched.
out="$(run_digest false resume "" 3 "In Progress" "- [ ] (directive) also report the 2019 cohort
")"
assert_contains "$(block "$out" "$RESUME_HDR")" "$ROW" \
  "a directive-marked resume is still a dispatch candidate"
assert_contains "$(block "$out" "$RESUME_HDR")" "$DIRECTIVE_MARK" \
  "an unchecked (directive) criterion marks the resume row distinctly (issue #77)" \
  "board-digest.sh must read the marker off the issue body it already has in the board JSON."
assert_eq 3 "$(gh_calls)" \
  "the directive-marked case makes the SAME 3 gh calls (board + closed search + pr list)" \
  "The marker is derived from the board JSON body — it must add no query (#77)."

# --- (h) a SATISFIED directive is not still pending --------------------------------
out="$(run_digest false resume "" 3 "In Progress" "- [x] (directive) already done
")"
assert_contains "$(block "$out" "$RESUME_HDR")" "$ROW" \
  "a resume row with a checked (directive) criterion is still listed"
assert_not_contains "$(block "$out" "$RESUME_HDR")" "$DIRECTIVE_MARK" \
  "a CHECKED (directive) criterion does not mark the row as pending" \
  "The marker tracks outstanding work; a satisfied directive must stop showing it (#77)."
assert_eq 3 "$(gh_calls)" \
  "the checked-directive case makes the same 3 gh calls"

# --- (i)-(l) the stale-pass bucket (issue #83) -------------------------------
MERGE_HDR="**Checker-passed PRs — ready to merge"
STALE_HDR="**⚠ STALE PASS"
PR_ROW="$SLUG#11 — Fixture PR"

# (i) checker saw this head: verdict comment NEWER than the head commit -> merge-ready.
out="$(run_digest false checked-pass "" 3 "In Progress" "" \
        2026-09-17T22:00:00Z 2026-09-17T22:48:42Z)"
assert_contains "$(block "$out" "$MERGE_HDR")" "$PR_ROW" \
  "a checked-pass PR whose head predates its verdict comment IS merge-ready" \
  "The stale-pass check must not demote a genuinely reviewed PR."
assert_not_contains "$out" "$STALE_HDR" \
  "…and no stale-pass bucket is emitted at all when nothing is stale"
assert_eq 3 "$(gh_calls)" \
  "the stale-pass check adds NO gh call (commits/comments ride the existing pr list)" \
  "Both fields were added to the pr list --json set; a per-PR lookup would add a call per PR."

# (j) THE OBSERVED BUG: commits pushed after the verdict, label still checked-pass.
#     Timestamps are distance-decay-est #73's, from the issue: verdict file 2026-09-17
#     22:48:42, round-2 commits the next morning.
out="$(run_digest false checked-pass "" 3 "In Progress" "" \
        2026-09-18T08:35:43Z 2026-09-17T22:48:42Z)"
assert_contains "$(block "$out" "$MERGE_HDR")" "- none" \
  "a head commit NEWER than the verdict is NOT offered as merge-ready (issue #83)" \
  "This is the check that would have caught #73/#44 without a human comparing mtimes."
assert_contains "$(block "$out" "$STALE_HDR")" "$PR_ROW" \
  "…it is reported as stale-pass instead of vanishing" \
  "Demoting it out of merge-ready must never drop it from the digest entirely."
assert_contains "$out" "2026-09-18T08:35:43Z" \
  "the stale-pass line names the head commit date it judged on"
assert_contains "$out" "2026-09-17T22:48:42Z" \
  "…and the verdict comment date it compared against"
assert_eq 3 "$(gh_calls)" "the stale case still makes the same 3 gh calls"

# (k) checked-pass with NO `**Checker verdict:` comment anywhere on the PR.
out="$(run_digest false checked-pass "" 3 "In Progress" "" 2026-09-18T08:35:43Z "")"
assert_contains "$(block "$out" "$MERGE_HDR")" "- none" \
  "checked-pass with no verdict comment at all is not merge-ready"
assert_contains "$(block "$out" "$STALE_HDR")" "$PR_ROW" \
  "…it is reported as stale-pass, with its own reason" \
  "A checker always posts the comment before labelling; its absence means the label is not a review."
assert_contains "$out" "no \`**Checker verdict:\` comment on this PR at all" \
  "the reason distinguishes 'never checked' from 'checked at an older head'"

# (l) UNKNOWABLE -> abstain. No commits/comments in the PR record (a fetch that did not
#     carry them) must leave the pre-#83 bucketing exactly as it was.
out="$(run_digest false checked-pass "" 3)"
assert_contains "$(block "$out" "$MERGE_HDR")" "$PR_ROW" \
  "with no commit/comment data the PR stays merge-ready (abstain, don't condemn)" \
  "A missing field is not evidence of staleness; the check must degrade to the old behavior."
assert_not_contains "$out" "$STALE_HDR" \
  "…and no stale-pass bucket is emitted"
assert_eq 3 "$(gh_calls)" "the abstaining case makes the same 3 gh calls"
