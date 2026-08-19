#!/usr/bin/env bash
# test-ledger-reconcile.sh (offline) — ledger-prune.sh's reconcile-before-prune pass
# (issue #63): a dispatch whose process died BEFORE finalize_dispatch used to sit at
# `status dispatched` against a dead pid and then be deleted silently, so a checker's
# COMPLETED review evaporated — verdict JSON on disk, no label applied, nothing countable
# posted, and the same PR due to be re-checked at a full CHECKER_BUDGET.
#
# Hermetic: a throwaway sandbox ORCH, a STATEFUL `gh` shim (labels/comments it is told to
# apply are visible to the next lookup, which is what makes idempotence testable at all),
# and a `tmux` shim that always reports "no session". Nothing dispatched, nothing spent, no
# network. Cases, matching the issue's acceptance criteria:
#   (a) dead pid + `dispatched` + a COMPLETE verdict -> label applied from the verdict file,
#       the recovered `**Checker verdict:` comment posted, terminal status, and a re-run
#       applies/posts NOTHING new
#   (b) dead pid + `dispatched` + NO verdict -> `incomplete-noverdict`, the countable
#       `**Checker incomplete:` comment posted, entry surfaced (not silently dropped)
#   (c) LIVE pid + `dispatched` -> untouched: not reconciled, not pruned, still `dispatched`
#   (d) a verdict JSON in logs/ that no ledger entry owns is reported when its label never
#       landed, and stays quiet when it did
#   (e) an entry pruned while STILL non-terminal (a `-` pid the reconciler cannot judge)
#       names itself, its log, and whether a verdict file was found
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" ledger-prune
LP="$SB/bin/ledger-prune.sh"

# A manifest so the reconciler can resolve repo + worktrees_dir for slug `demo`.
cat >"$SB/projects/demo.yml" <<YML
repo: owner/demo
data_root: $SB/data
worktrees_dir: $SB/worktrees
YML

# --- shims --------------------------------------------------------------------
SHIMS="$(sandbox_tmp)"
export GH_CALLS="$SHIMS/gh-calls.txt"
export GH_STATE="$SHIMS/state"
mkdir -p "$GH_STATE"
: >"$GH_CALLS"

# `tmux` always reports no session, so assert_finalized's `waiting` rung never fires and
# the reconciled status is decided by the verdict file alone.
cat >"$SHIMS/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in has-session) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$SHIMS/tmux"

# STATEFUL gh shim. $GH_STATE/labels and $GH_STATE/pr-comments are the fake GitHub: a
# `--add-label` / `pr comment` writes there and the matching `view` reads it back, so a
# second reconcile sees the world its predecessor left — the only way to prove idempotence
# rather than just "it ran twice". $GH_STATE/draft records a `pr ready --undo`.
#   FAKE_PR_STATE   OPEN | MERGED   (`pr view --json state`, and the composite lookup)
#   FAKE_ISSUE_STATE OPEN | CLOSED  (`issue view --json state`, the prune's own lookup)
cat >"$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
LABELS="$GH_STATE/labels"; COMMENTS="$GH_STATE/pr-comments"; DRAFT="$GH_STATE/draft"
body=""
prev=""
for a in "$@"; do
  [ "$prev" = "--body" ] && body="$a"
  [ "$prev" = "--add-label" ] && printf '%s\n' "$a" >>"$LABELS"
  prev="$a"
done
json_labels() {
  python3 - "$LABELS" <<'PY'
import json, sys
try:
    names = [l.strip() for l in open(sys.argv[1]) if l.strip()]
except OSError:
    names = []
print(json.dumps({"labels": [{"name": n} for n in names]}))
PY
}
json_pr() {   # $1 = fields requested
  BODYFILE="$COMMENTS" DRAFTFILE="$DRAFT" PRSTATE="${FAKE_PR_STATE:-OPEN}" python3 <<'PY'
import json, os
try:
    bodies = [b for b in open(os.environ["BODYFILE"]).read().split("\x00") if b.strip()]
except OSError:
    bodies = []
print(json.dumps({
    "state": os.environ["PRSTATE"],
    "isDraft": os.path.exists(os.environ["DRAFTFILE"]),
    "comments": [{"body": b} for b in bodies],
    "closingIssuesReferences": [{"number": 48}],
}))
PY
}
case "$1 ${2:-}" in
  "pr comment")     printf '%s\x00' "$body" >>"$COMMENTS"; exit 0 ;;
  "issue comment")  exit 0 ;;
  "issue edit")     exit 0 ;;
  "pr ready")       : >"$DRAFT"; exit 0 ;;
  "pr view")
    case " $* " in
      *" --json state "*) printf '{"state":"%s"}\n' "${FAKE_PR_STATE:-OPEN}" ;;
      *)                  json_pr ;;
    esac
    exit 0 ;;
  "issue view")
    case " $* " in
      *" --json labels "*)   json_labels ;;
      *" --json state "*)    printf '{"state":"%s"}\n' "${FAKE_ISSUE_STATE:-OPEN}" ;;
      *" --json comments "*) echo '{"comments":[]}' ;;
      *)                     echo '{}' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
chmod +x "$SHIMS/gh"
export PATH="$SHIMS:$PATH"

# --- fixtures -----------------------------------------------------------------
CHECKER_LOG="$SB/logs/demo-pr-64.log"
VERDICT="$SB/logs/demo-pr-64-verdict.json"
: >"$CHECKER_LOG"          # the observed failure had a 0-byte log: no result JSON at all
DEAD_PID=99999999
LED="$SB/ledger.md"

write_checker_ledger() {   # $1 = pid
  cat >"$LED" <<LEDGER
- check pr#64 | owner/demo | issue-48 | $CHECKER_LOG | pid $1 | dispatched 2026-08-04T18:34:34Z | status dispatched
LEDGER
}
write_verdict() {          # $1 = verdict token
  cat >"$VERDICT" <<JSON
{"pr": 64, "issue": 48, "verdict": "$1", "findings": [],
 "evidence": ["./bin/test.sh"], "failure_class": "none", "mutation_delta": ""}
JSON
}
run_prune() { LEDGER="$LED" "$LP" 2>&1; }
reset_github() { : >"$GH_CALLS"; rm -f "$GH_STATE/labels" "$GH_STATE/pr-comments" "$GH_STATE/draft"; }

# ── (a) verdict complete: the review is recovered, not thrown away ────────────
reset_github
write_verdict pass_with_findings
write_checker_ledger "$DEAD_PID"
out="$(run_prune)"

assert_contains "$out" "reconciling checker owner/demo#64" \
  "a dead-pid dispatched checker is reconciled before the prune decides" \
  "ledger-prune.sh must reconcile dead-pid non-terminal entries (issue #63)."
assert_contains "$out" "reconciled: status dispatched -> done" \
  "a complete verdict reconciles to a terminal status" \
  "classify_result says unknown on a 0-byte log; reconciled_status must still run the battery."
assert_contains "$(cat "$GH_CALLS")" "--add-label checked-pass" \
  "a pass_with_findings verdict applies checked-pass to the closing ISSUE" \
  "The label is the outcome of a completed review — without it the PR never reaches the merge gate."
assert_contains "$(cat "$GH_CALLS")" "issue edit 48 -R owner/demo" \
  "the label goes on the issue the verdict names, not the PR" \
  "Routing labels live on the closing issue (briefs/checker-brief.md)."
assert_contains "$(cat "$GH_STATE/pr-comments")" "**Checker verdict: pass_with_findings**" \
  "the recovered verdict is posted as a countable **Checker verdict: comment" \
  "CHECKER_ROUND_LEADS counts this lead; on disk the findings are invisible to everyone."
assert_not_contains "$(cat "$GH_STATE/pr-comments")" "**Checker incomplete:" \
  "no incomplete round is posted for a review that completed" \
  "The label is the outcome here — an incomplete comment would claim the round decided nothing."
assert_not_contains "$(cat "$GH_STATE/pr-comments")" "**Checker interrupted:" \
  "no interrupted round is posted for a review that completed" \
  "Same as above: a completed review must not burn a CHECKER_LIMIT round."
assert_not_contains "$(cat "$GH_CALLS")" "pr ready 64" \
  "a to-operator verdict leaves the PR ready" \
  "Only changes_requested/fail flips a PR back to draft."
assert_contains "$out" "pruned:" \
  "the reconciled entry is then pruned (its pid is dead)" \
  "Reconciliation is a pre-step to pruning, not a replacement for it."

# idempotence: re-seed the same line and reconcile again against the state the first run
# left. Nothing new may be applied or posted.
nlabel1="$(grep -c -- '--add-label' "$GH_CALLS" || true)"
ncomment1="$(grep -c -- '^pr comment' "$GH_CALLS" || true)"
: >"$GH_CALLS"
write_checker_ledger "$DEAD_PID"
out_again="$(run_prune)"
assert_eq "0" "$(grep -c -- '--add-label' "$GH_CALLS" || true)" \
  "a second reconcile applies no label (already present)" \
  "publish_recovered_verdict must read the labels before adding one — issue #63 idempotence."
assert_eq "0" "$(grep -c -- '^pr comment' "$GH_CALLS" || true)" \
  "a second reconcile posts no comment (the verdict comment is already on the PR)" \
  "It must detect its own (or the checker's) **Checker verdict: comment and stay quiet."
assert_eq "1" "$nlabel1" "the FIRST reconcile applied exactly one label" \
  "One label per recovered verdict — no retry storms."
assert_eq "1" "$ncomment1" "the FIRST reconcile posted exactly one comment" \
  "One recovered verdict comment per dispatch."
assert_contains "$out_again" "already on #48" \
  "the second run says the label was already there" \
  "A no-op reconcile must still be legible in the log."

# a worker-court verdict routes differently: `resume` + the PR back to draft (without the
# flip, board-digest strands a ready PR whose issue carries `resume` in NO bucket).
reset_github
write_verdict changes_requested
write_checker_ledger "$DEAD_PID"
out_cr="$(run_prune)"
assert_contains "$(cat "$GH_CALLS")" "--add-label resume" \
  "a changes_requested verdict applies resume" \
  "The verdict -> label map must mirror briefs/checker-brief.md."
assert_contains "$(cat "$GH_CALLS")" "pr ready 64 -R owner/demo --undo" \
  "a changes_requested verdict also flips the PR back to draft" \
  "A ready PR labeled resume is dispatched to nobody (board-digest.sh classification)."

# ── (b) no verdict: a countable incomplete round, not a silent deletion ───────
reset_github
rm -f "$VERDICT"
write_checker_ledger "$DEAD_PID"
out_nv="$(run_prune)"
assert_contains "$out_nv" "reconciled: status dispatched -> incomplete-noverdict" \
  "a dead checker with no verdict reconciles to incomplete-noverdict" \
  "assert_finalized's noverdict rung must decide this — the whole deliverable is missing."
assert_contains "$(cat "$GH_STATE/pr-comments")" "**Checker incomplete: incomplete-noverdict**" \
  "the countable **Checker incomplete: comment is posted" \
  "Without it CHECKER_LIMIT never advances and the PR is re-checked every cycle (issue #52's hole, reopened)."
assert_contains "$out_nv" "⚠ was incomplete-noverdict" \
  "the pruned entry is surfaced with its reconciled status" \
  "The reconciled status must reach the ledger line BEFORE the prune reads it."
assert_contains "$out_nv" "no usable verdict at" \
  "the missing verdict file is named" \
  "An operator reading the cycle log must be able to see why the round decided nothing."

# ── (c) a LIVE pid is never touched ──────────────────────────────────────────
reset_github
write_verdict pass
write_checker_ledger "$$"
out_live="$(run_prune)"
assert_not_contains "$out_live" "reconciling" \
  "a live-pid dispatched entry is not reconciled" \
  "A running session's finalize_dispatch is still to come — reconciling would race it."
assert_eq "0" "$(grep -c -- '--add-label' "$GH_CALLS" || true)" \
  "a live-pid entry applies no label" \
  "Nothing may be published on behalf of a session that is still working."
assert_contains "$(cat "$LED")" "status dispatched" \
  "the live entry keeps its dispatched status" \
  "Only a dead pid may be reconciled."
assert_contains "$out_live" "kept 1 live" \
  "the live entry is kept, not pruned" \
  "The concurrency cap depends on live entries surviving the prune."

# ── (d) the unowned-verdict sweep ────────────────────────────────────────────
# A verdict JSON no ledger entry points at: the shape left behind when the line was
# already dropped (by any prune that ran before this reconciler existed).
reset_github
: >"$LED"                                    # no entry owns anything
write_verdict pass
out_sweep="$(run_prune)"
assert_contains "$out_sweep" "UNROUTED VERDICT" \
  "a verdict file with no ledger entry and no applied label is reported" \
  "The orphaned-verdict case must be detectable (issue #63)."
assert_contains "$out_sweep" "carries no \`checked-pass\`" \
  "the report names the label that never landed" \
  "The warning has to be actionable without opening the JSON."
assert_eq "0" "$(grep -c -- '--add-label' "$GH_CALLS" || true)" \
  "the sweep reports and does NOT apply anything" \
  "With no ledger entry there is no dispatch context — applying a label off an unknown-vintage file is unsafe."

printf 'checked-pass\n' >"$GH_STATE/labels"   # the outcome DID land
out_quiet="$(LEDGER="$LED" "$LP" 2>&1)"
assert_not_contains "$out_quiet" "UNROUTED VERDICT" \
  "a verdict whose label already landed is not reported" \
  "Every normally-finished checker leaves a verdict file behind; only unrouted ones are findings."

reset_github
out_merged="$(FAKE_PR_STATE=MERGED LEDGER="$LED" "$LP" 2>&1)"
assert_not_contains "$out_merged" "UNROUTED VERDICT" \
  "a verdict on a closed/merged PR is not reported" \
  "A merged PR's verdict is moot — reporting it would be pure noise."

# ── (e) a prune that drops a still-non-terminal entry says so ────────────────
# pid `-` (a --foreground dispatch) is unknowable, so the reconciler leaves it alone; the
# prune reason is the CLOSED issue. That combination used to delete the line in silence.
reset_github
WORKER_LOG="$SB/logs/demo-issue-10.log"
: >"$WORKER_LOG"
cat >"$LED" <<LEDGER
- #10 | owner/demo | issue-10 | $WORKER_LOG | pid - | dispatched 2026-08-04T18:34:34Z | status dispatched
LEDGER
out_fg="$(FAKE_ISSUE_STATE=CLOSED run_prune)"
assert_contains "$out_fg" "⚠ NOT reconciled" \
  "an entry pruned while still non-terminal is surfaced" \
  "Silent deletion of an unreconciled dispatch is the #63 hole — it must warn."
assert_contains "$out_fg" "$WORKER_LOG" \
  "the warning names the entry's log path" \
  "The log is the only remaining evidence — the warning must point at it."
assert_contains "$out_fg" "verdict file absent" \
  "the warning reports whether a verdict file was found" \
  "Acceptance criterion: the warning names the log AND the verdict-file state."
