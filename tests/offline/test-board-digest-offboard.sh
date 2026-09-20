#!/usr/bin/env bash
# test-board-digest-offboard.sh (OFFLINE) — board-digest.sh's OFF-BOARD mode (issue #86),
# run against fixture JSON through a `gh` shim. No network, no real conf, no real board:
# every case builds its own throwaway ORCH sandbox.
#
# What off-board mode is: a repo can be onboarded to the loop and deliberately absent
# from the cross-repo board. `board: none` in projects/<slug>.yml switches that slug's
# ISSUE SOURCE from board rows to `gh issue list`, and — because there is no board Status
# field to promote with — the `up-next` LABEL stands in for Status "Up Next".
#
# The two things most worth pinning, because both fail SILENTLY:
#   * the promotion gate. Without the `up-next` stand-in, EVERY open issue in the repo
#     becomes a dispatch candidate at once — the opposite of the intake discipline the
#     digest exists to enforce. Cases (a)/(b) pin both directions.
#   * a failing `gh issue list`. Degrading to zero issues with no note renders an empty
#     dispatch bucket that reads exactly like "nothing to do" (cases (i)/(j)).
# Case (l) is the non-regression half: a manifest with no `board:` key and one with a
# non-`none` value must produce byte-identical output and make ZERO extra gh calls.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 \
  || { skip "python3 not installed — skipping board-digest off-board mode"; exit 0; }

OWNER="test-operator"              # PR_OWNER in write_filled_conf
OB_SLUG="offboard"                 # the off-board repo
BD_SLUG="fixture"                  # a board-sourced repo (mixed-digest cases)
OB_REPO="$OWNER/$OB_SLUG"
OB_ISSUE=7

# run_digest — build a sandbox for one case and echo the digest it produces.
# Configured by environment, set by the caller before the call (the function runs in a
# $(…) subshell, so anything it sets dies with that subshell — CALLS_LOG therefore lives
# in the sandbox ROOT, not in the per-case sandbox).
#   OB_LABELS   labels on the single off-board issue #7 (comma-separated, may be empty)
#   OB_MODE     ok | fail | garbage | empty   — what the `gh issue list` shim does
#   OB_BOARD    none | <other value> | (empty = the `board:` key is ABSENT)
#   OB_PR       ""|draft|ready — an open PR #21 in the off-board repo
#   OB_CLOSES   the issue number that PR declares it closes (default 7)
#   OB_PID      a live pid, to fake an in-flight worker on off-board #7
#   OB_MIXED    1 to also onboard the board-sourced `fixture` repo (one Up Next row)
run_digest() {
  local sb shim labels
  sb="$(new_sandbox)"
  sandbox_copy_script "$sb" board-digest
  cp "$REPO_ROOT/bin/config-common.sh" "$sb/bin/config-common.sh"
  write_filled_conf "$sb"

  # --- manifests -------------------------------------------------------------
  write_project_manifest "$sb" "$OB_SLUG" "$OB_REPO"
  printf 'project: Personal\n' >> "$sb/projects/$OB_SLUG.yml"
  [ -n "${OB_BOARD:-}" ] && printf 'board: %s\n' "$OB_BOARD" >> "$sb/projects/$OB_SLUG.yml"
  if [ "${OB_MIXED:-}" = "1" ]; then
    write_project_manifest "$sb" "$BD_SLUG" "$OWNER/$BD_SLUG"
    printf 'project: Research\n' >> "$sb/projects/$BD_SLUG.yml"
  fi

  # --- board JSON: empty unless the case is a mixed digest -------------------
  if [ "${OB_MIXED:-}" = "1" ]; then
    BD_URL="https://github.com/$OWNER/$BD_SLUG" python3 - "$sb/board.json" <<'PY'
import json, os, sys
json.dump({"items": [{
    "title": "Board issue", "status": "Up Next", "project": "Research",
    "repository": os.environ["BD_URL"], "labels": [],
    "content": {"type": "Issue", "number": 5, "title": "Board issue",
                "body": "Lead line.\n\n- [ ] a criterion"},
}]}, open(sys.argv[1], "w"))
PY
  else
    printf '{"items": []}\n' > "$sb/board.json"
  fi

  # --- off-board `gh issue list` payload -------------------------------------
  mkdir -p "$sb/issues"
  case "${OB_MODE:-ok}" in
    fail)    printf 'FAIL\n'    > "$sb/issues/$OB_SLUG" ;;
    garbage) printf 'GARBAGE\n' > "$sb/issues/$OB_SLUG" ;;
    empty)   printf '[]\n'      > "$sb/issues/$OB_SLUG.json" ;;
    *)
      LABELS="${OB_LABELS:-}" NUM="$OB_ISSUE" python3 - "$sb/issues/$OB_SLUG.json" <<'PY'
import json, os, sys
labels = [{"name": l} for l in os.environ["LABELS"].split(",") if l]
json.dump([{"number": int(os.environ["NUM"]), "title": "Off-board issue",
            "body": "Off-board lead line.\n\n- [ ] an off-board criterion",
            "labels": labels}], open(sys.argv[1], "w"))
PY
      ;;
  esac

  # --- open PRs, per repo ----------------------------------------------------
  mkdir -p "$sb/prs"
  if [ -n "${OB_PR:-}" ]; then
    DRAFT="$([ "$OB_PR" = draft ] && echo true || echo false)" \
    CLOSES="${OB_CLOSES:-$OB_ISSUE}" OB_REPO="$OB_REPO" \
      python3 - "$sb/prs/$OB_SLUG.json" <<'PY'
import json, os, sys
json.dump([{
    "number": 21, "title": "Off-board PR",
    "url": f"https://github.com/{os.environ['OB_REPO']}/pull/21",
    "isDraft": os.environ["DRAFT"] == "true", "reviewDecision": "",
    "headRefName": "issue-7",
    "closingIssuesReferences": [{"number": int(os.environ["CLOSES"])}],
    "labels": [],
}], open(sys.argv[1], "w"))
PY
  fi

  # --- ledger ----------------------------------------------------------------
  if [ -n "${OB_PID:-}" ]; then
    printf -- '- #%s | %s | issue-%s | %s/logs/w.log | pid %s | dispatched 2026-09-19T00:00:00Z | status dispatched\n' \
      "$OB_ISSUE" "$OB_REPO" "$OB_ISSUE" "$sb" "$OB_PID" > "$sb/ledger.md"
  fi

  # --- gh shim: answers only the calls the digest makes, logging every one so
  #     the network-budget criterion is checkable rather than asserted. -------
  shim="$(sandbox_tmp)"
  cat >"$shim/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
repo=""
prev=""
for a in "$@"; do [ "$prev" = "-R" ] && repo="${a##*/}"; prev="$a"; done
case "$1 $2" in
  "project item-list") cat "$GH_BOARD" ;;
  "search issues")     echo '[]' ;;
  "pr list")           [ -f "$GH_DIR/prs/$repo.json" ] && cat "$GH_DIR/prs/$repo.json" || echo '[]' ;;
  "issue list")
      if [ -f "$GH_DIR/issues/$repo" ]; then
        case "$(cat "$GH_DIR/issues/$repo")" in
          FAIL)    echo "gh: HTTP 403: rate limit exceeded" >&2; exit 1 ;;
          GARBAGE) echo "not json at all" ;;
        esac
      elif [ -f "$GH_DIR/issues/$repo.json" ]; then
        cat "$GH_DIR/issues/$repo.json"
      else
        echo '[]'
      fi ;;
  "issue view")        echo '{"title":"looked-up issue","state":"OPEN"}' ;;
  *) echo "gh shim: unexpected call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$shim/gh"
  # A real tmux would probe the operator's live sessions; keep the case hermetic.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/tmux"; chmod +x "$shim/tmux"

  : >"$CALLS_LOG"
  PATH="$shim:$PATH" GH_BOARD="$sb/board.json" GH_DIR="$sb" GH_CALLS="$CALLS_LOG" \
    "$sb/bin/board-digest.sh"
}

# reset_case — clear every knob so a case only sets what it means to.
reset_case() { OB_LABELS=""; OB_MODE=ok; OB_BOARD=none; OB_PR=""; OB_CLOSES=""; OB_PID=""; OB_MIXED=""; }

block() {  # $1 = digest text, $2 = header substring -> the lines under that header
  awk -v pat="$2" '
    index($0, pat) { on = 1; next }
    on && (/^\*\*/ || /^## /) { exit }
    on { print }
  ' <<<"$1"
}
count_of() { grep -cF -- "$2" <<<"$1" || true; }

CALLS_LOG="$_SANDBOX_ROOT/gh-calls.log"
gh_calls() { wc -l <"$CALLS_LOG" | tr -d ' '; }
gh_issue_list_calls() { grep -c '^issue list' "$CALLS_LOG" || true; }

ACT_HDR="**actionable, no open PR (Up Next / In Progress)"
RESUME_HDR="**resume — revisions to re-dispatch"
CHECK_HDR="**Ready PRs awaiting checker"
NI_HDR="**needs-input ("
ND_HDR="**needs-definition ("
UNROUTED_HDR="closing issue not on the board"
OB_ROW="$OB_SLUG#$OB_ISSUE — Off-board issue"

# --- (a) `up-next` promotes an off-board issue into the actionable bucket ----
reset_case; OB_LABELS="up-next"
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "$OB_ROW" \
  "an off-board issue labelled up-next is a dispatch candidate (issue #86)" \
  "board-digest.sh must source it from gh issue list and map up-next -> Status 'Up Next'."
assert_contains "$(block "$out" "$ACT_HDR")" "[Personal]" \
  "…tagged with the manifest's project: value (the key's first real use)"
assert_contains "$(block "$out" "$ACT_HDR")" "- [ ] an off-board criterion" \
  "…and carrying its acceptance criteria, so the intake gate applies off-board too"
assert_contains "$out" "## Dispatch candidates — worker's court (1)" \
  "the off-board issue is counted as a candidate"
assert_contains "$out" "\`board: none\`" \
  "the header says which repos are off-board and what the stand-in is"
assert_eq 1 "$(gh_issue_list_calls)" \
  "off-board mode costs EXACTLY ONE \`gh issue list\` for the slug" \
  "The documented network budget is one call per off-board slug — no more."
assert_eq 4 "$(gh_calls)" \
  "…so the run makes 4 gh calls: board + closed search + 1 pr list + 1 issue list"

# --- (b) no `up-next` -> Backlog, NOT a dispatch candidate -------------------
reset_case
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "an off-board issue WITHOUT up-next is not actionable (the promotion gate holds)" \
  "Without the stand-in every open issue becomes a candidate at once — the intake gate's whole point."
assert_contains "$out" "### Backlog (1)" \
  "…it is still visible, collapsed into the Backlog count"
assert_contains "$out" "Personal 1" \
  "…broken down by its manifest project: value"

# --- (c) hold / blocked still park an off-board issue ------------------------
for park in hold blocked; do
  reset_case; OB_LABELS="up-next,$park"
  out="$(run_digest)"
  assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
    "$park excludes an up-next off-board issue from actionable (the existing filter, not a special case)"
  assert_contains "$out" "## Excluded from dispatch" \
    "…and it is reported in the excluded section"
done

# --- (d) needs-input -> the operator's court ---------------------------------
reset_case; OB_LABELS="needs-input"
out="$(run_digest)"
assert_contains "$(block "$out" "$NI_HDR")" "$OB_ROW" \
  "an off-board needs-input issue reaches the operator's court bucket"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "…and, unpromoted (no up-next), is not a dispatch candidate"
# The acceptance criterion is explicit that the `actionable` filter is applied VERBATIM
# off-board, not special-cased. It does not (and never did) exclude `needs-input`, so an
# off-board issue carrying BOTH `up-next` and `needs-input` is a candidate — exactly as a
# board-sourced `Up Next` + `needs-input` row is today. Pinned so the parity is
# deliberate and visible rather than an accident of ordering.
reset_case; OB_LABELS="up-next,needs-input"
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "$OB_ROW" \
  "up-next + needs-input is actionable off-board, matching board mode's filter exactly" \
  "The filter at board-digest.sh's actionable list must not be special-cased for off-board rows."
assert_contains "$(block "$out" "$NI_HDR")" "$OB_ROW" \
  "…while still surfacing in the operator's needs-input bucket, as on the board"

# --- (e) needs-definition -> operator's court --------------------------------
reset_case; OB_LABELS="up-next,needs-definition"
out="$(run_digest)"
assert_contains "$(block "$out" "$ND_HDR")" "$OB_ROW" \
  "an off-board needs-definition issue reaches the needs-definition bucket"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "…and is excluded from actionable by the existing filter"

# --- (f) a bare `resume` with no open PR -> the resume bucket ----------------
reset_case; OB_LABELS="resume"
out="$(run_digest)"
assert_contains "$(block "$out" "$RESUME_HDR")" "$OB_ROW" \
  "an off-board issue labelled resume lands in the resume bucket"

# --- (g) an open PR means the issue is in the loop, not dispatchable ---------
reset_case; OB_LABELS="up-next"; OB_PR=draft
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "an off-board issue with an open PR is NOT a fresh dispatch candidate"
assert_contains "$(block "$out" "$RESUME_HDR")" "$OB_ROW" \
  "…its draft PR routes to the worker's court as its issue row"
assert_not_contains "$out" "$UNROUTED_HDR" \
  "the 'closing issue not on the board' ⚠ does NOT fire for an issue found via gh issue list" \
  "Firing it for every off-board PR would be the permanent-false-alarm failure of #85."

reset_case; OB_LABELS="up-next"; OB_PR=ready
out="$(run_digest)"
assert_contains "$(block "$out" "$CHECK_HDR")" "$OB_SLUG#21" \
  "an off-board ready PR routes to the checker's court exactly as a board-sourced one does"
assert_not_contains "$out" "$UNROUTED_HDR" \
  "…with no spurious not-on-the-board warning"

# --- (g2) a PR closing an issue that ISN'T open -> reported, with off-board wording ---
reset_case; OB_LABELS="up-next"; OB_PR=draft; OB_CLOSES=99
out="$(run_digest)"
assert_contains "$out" "$UNROUTED_HDR" \
  "a genuinely unresolvable closing reference is still reported off-board"
assert_contains "$(block "$out" "$UNROUTED_HDR")" "off-board repo" \
  "…with advice the operator can act on, not 'add it to the board'" \
  "There is no board to add it to; the honest read is that no OPEN issue matched."

# --- (h) a live ledger entry suppresses the candidate ------------------------
reset_case; OB_LABELS="up-next"; OB_PID="$$"
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "a live ledger entry excludes an off-board issue from actionable"
assert_contains "$out" "⚙ in-flight" \
  "…and the in-flight worker is visible on its row"
assert_contains "$out" "Off-board issue" \
  "…with its title joined from the off-board row, not a per-issue gh lookup"
assert_eq 4 "$(gh_calls)" \
  "the in-flight join costs no extra gh call off-board" \
  "The off-board rows feed the same in-flight join map the ledger reads."

# --- (i) a FAILING `gh issue list` degrades visibly, never silently ----------
reset_case; OB_MODE=fail
out="$(run_digest)"
assert_contains "$out" "its issues are MISSING from this digest" \
  "a failing gh issue list is reported in a visible one-line note" \
  "Degrading to zero issues silently renders an empty bucket that reads like 'nothing to do'."
assert_contains "$out" "rate limit exceeded" \
  "…naming the actual gh error rather than a generic 'failed'"
assert_contains "$out" "## Dispatch candidates" \
  "…and the digest still completes end to end"
assert_contains "$(block "$out" "$ACT_HDR")" "could not be fetched" \
  "…with the dispatch bucket itself disclaiming the missing repo" \
  "An empty candidate list must not be readable as 'their queue is empty'."

# --- (j) UNPARSEABLE output is the same class of failure ---------------------
reset_case; OB_MODE=garbage
out="$(run_digest)"
assert_contains "$out" "unparseable output" \
  "unparseable gh issue list output degrades to the same visible note"
assert_contains "$out" "## Dispatch candidates" \
  "…and still never aborts the run"

# --- (k) a MIXED digest renders board-sourced and off-board repos together ---
reset_case; OB_LABELS="up-next"; OB_MIXED=1
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "$OB_ROW" \
  "a mixed digest lists the off-board candidate"
assert_contains "$(block "$out" "$ACT_HDR")" "$BD_SLUG#5 — Board issue" \
  "…and the board-sourced candidate, in one report"
assert_contains "$(block "$out" "$ACT_HDR")" "[Research]" \
  "…each tagged by its own project value"
assert_eq 0 "$(count_of "$out" "$UNROUTED_HDR")" \
  "a mixed digest raises no 'closing issue not on the board' warning" \
  "Validation check #4 of issue #86: expected count is 0."
assert_eq 1 "$(gh_issue_list_calls)" \
  "the board-sourced repo costs NO gh issue list — only the off-board slug does"
assert_eq 5 "$(gh_calls)" \
  "mixed: board + closed search + 2 pr list + 1 issue list = 5 gh calls"

# --- (l) NON-REGRESSION: board mode is untouched by the new key --------------
# `board:` absent and `board:` set to a non-`none` value must be indistinguishable
# from each other AND make zero `gh issue list` calls. (The 12-case
# test-board-digest-buckets.sh is the unchanged behavioral pin for board mode itself;
# this case pins that the new key's two inert states stay inert.)
reset_case; OB_LABELS="up-next"; OB_BOARD=""; OB_MIXED=1
absent="$(run_digest)"; absent_calls="$(gh_calls)"; absent_il="$(gh_issue_list_calls)"
reset_case; OB_LABELS="up-next"; OB_BOARD="3"; OB_MIXED=1
other="$(run_digest)";  other_calls="$(gh_calls)";  other_il="$(gh_issue_list_calls)"
# The first line is a wall-clock timestamp; everything after it is the digest proper.
assert_eq "$(tail -n +2 <<<"$absent")" "$(tail -n +2 <<<"$other")" \
  "a manifest with NO board: key and one with a non-'none' value render identically" \
  "Only the literal value 'none' may change behavior; anything else is today's board mode."
assert_eq 0 "$absent_il" "no board: key makes ZERO gh issue list calls"
assert_eq 0 "$other_il"  "a non-'none' board: value makes ZERO gh issue list calls"
assert_eq 4 "$absent_calls" "board mode's call count is unchanged (board + closed + 2 pr list)"
assert_eq 4 "$other_calls"  "…for both inert states"
assert_not_contains "$absent" "\`board: none\`" \
  "board mode emits no off-board header line at all"
assert_not_contains "$absent" "$OB_ROW" \
  "a board-mode repo with no board row contributes no issues (pre-change behavior)" \
  "gh issue list must not be consulted for a repo that is not declared off-board."

# --- (m) case-insensitivity, per the acceptance criterion --------------------
reset_case; OB_LABELS="up-next"; OB_BOARD="NONE"
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "$OB_ROW" \
  "board: NONE selects off-board mode too (the value is case-insensitive)"

# --- (n) an off-board repo with zero open issues is honest, not alarming -----
reset_case; OB_MODE=empty
out="$(run_digest)"
assert_contains "$(block "$out" "$ACT_HDR")" "- none" \
  "an off-board repo with no open issues yields no candidates"
assert_not_contains "$out" "MISSING from this digest" \
  "…and a genuinely empty repo is NOT reported as a fetch failure" \
  "The warning must distinguish 'nothing there' from 'could not look'."
