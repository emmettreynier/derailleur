#!/usr/bin/env bash
# test-routing-labels.sh (OFFLINE) — the mutual exclusion of the three routing labels
# (`checked-pass`, `resume`, `needs-input`) and its single owner, `set_routing_label`
# in bin/dispatch-common.sh.
#
# THE BUG THIS PINS (issue #83). The three labels encode WHOSE COURT the work is in, so
# at most one may ever be on an issue — and nothing enforced that: every write site used
# a bare `--add-label`, and `bin/` contained no `--remove-label` at all. Observed twice on
# 2026-09-18 (distance-decay-est #73 and #44): a checker passes -> `checked-pass`; a new
# round is opened -> `resume`; the worker finalizes and clears `resume`; `checked-pass`
# REMAINS on a PR now carrying commits no checker has ever seen. `board-digest.sh` then
# buckets it as merge-ready, and `orchestrator-cycle.sh` skips dispatching a checker on
# ANY `checked-pass` issue — so on the unattended path the PR is never checked at all.
#
# Hermetic: a throwaway sandbox ORCH and a STATEFUL `gh` shim whose label set really
# honours `--add-label` / `--remove-label`, so "the other label is gone" is observed
# rather than inferred from the argv. No network, no real conf, nothing dispatched.
#
# Cases:
#   (a) checked-pass -> resume: resume present, checked-pass GONE, in ONE `gh issue edit`
#   (b) resume -> checked-pass: the mirror direction
#   (c) idempotent: re-routing the label already in place writes NOTHING
#   (d) a third label present (needs-input + resume) is cleared too; non-routing labels
#       (`hold`, `needs-definition`) are never touched
#   (e) fail-soft: no `gh` on PATH, a failing `gh issue edit`, a non-routing label
#       argument, and a missing repo/issue each return 1 and leave the issue untouched
#   (f) a failed labels LOOKUP still routes (unconditional add+remove form)
#   (g) end-to-end through ledger-prune.sh: its `resume` relabel clears a stale
#       `checked-pass` (the exact observed sequence), via the shell helper
#   (h) the invariant's blast radius: `bin/` contains no routing-label `--add-label`
#       outside the helper, and briefs/checker-brief.md emits the clearing form at all
#       three verdicts
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" config-common
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" ledger-prune

# --- stateful gh shim ---------------------------------------------------------
# $GH_STATE/labels IS the fake issue's label set: `--add-label` appends, `--remove-label`
# deletes, and `issue view --json labels` reads it back. That statefulness is the whole
# point — an add-only regression would still LOG a plausible argv, so the assertions read
# the resulting set, not the call.
#   FAKE_EDIT_FAIL   non-empty -> every `gh issue edit` exits 1 (the fail-soft path)
#   FAKE_VIEW_FAIL   non-empty -> every `gh issue view --json labels` exits 1 (lookup
#                    failure -> the unconditional fallback form)
SHIMS="$(sandbox_tmp)"
export GH_CALLS="$SHIMS/gh-calls.txt"
export GH_STATE="$SHIMS/state"
mkdir -p "$GH_STATE"
: >"$GH_CALLS"

cat >"$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
LABELS="$GH_STATE/labels"
case "$1 ${2:-}" in
  "issue edit")
    [ -n "${FAKE_EDIT_FAIL:-}" ] && exit 1
    # All-or-nothing, like the real API call: apply every add/remove of ONE invocation
    # to a copy, then swap it in. A half-applied edit here would hide the very thing the
    # helper's "one call, not two" discipline exists to guarantee.
    tmp="$LABELS.tmp"; cp -f "$LABELS" "$tmp" 2>/dev/null || : >"$tmp"
    prev=""
    for a in "$@"; do
      case "$prev" in
        --add-label)    grep -qxF -- "$a" "$tmp" || printf '%s\n' "$a" >>"$tmp" ;;
        --remove-label) grep -vxF -- "$a" "$tmp" >"$tmp.2" || : ; mv -f "$tmp.2" "$tmp" ;;
      esac
      prev="$a"
    done
    mv -f "$tmp" "$LABELS"; exit 0 ;;
  "issue view")
    case " $* " in
      *" --json labels "*)
        [ -n "${FAKE_VIEW_FAIL:-}" ] && exit 1
        python3 - "$LABELS" <<'PY'
import json, sys
try:    names = [l.strip() for l in open(sys.argv[1]) if l.strip()]
except OSError: names = []
print(json.dumps({"labels": [{"name": n} for n in names]}))
PY
        exit 0 ;;
      *" --json state "*)    printf '{"state":"%s"}\n' "${FAKE_ISSUE_STATE:-OPEN}"; exit 0 ;;
      *" --json comments "*)
        # FAKE_INTERRUPTED=N -> N trailing `**Worker interrupted:` comments, which is what
        # ledger-prune's WORKER_LIMIT escalation counts.
        python3 -c 'import json,os,sys
n = int(os.environ.get("FAKE_INTERRUPTED") or 0)
print(json.dumps({"comments": [{"body": "**Worker interrupted: interrupted-ratelimit"} for _ in range(n)]}))'
        exit 0 ;;
    esac
    echo '{}'; exit 0 ;;
  "pr list")   echo '[{"closingIssuesReferences":[{"number":48}]}]'; exit 0 ;;
  "pr view")   echo '{"state":"OPEN"}'; exit 0 ;;
  "issue comment") exit 0 ;;
esac
exit 0
SH
chmod +x "$SHIMS/gh"
export PATH="$SHIMS:$PATH"

# --- harness ------------------------------------------------------------------
# shellcheck disable=SC1090
. "$SB/bin/dispatch-common.sh"

set_labels() { printf '%s\n' "$@" | grep -v '^$' >"$GH_STATE/labels" || : >"$GH_STATE/labels"; }
labels_now() { sort "$GH_STATE/labels" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
reset_gh()   { : >"$GH_CALLS"; : >"$GH_STATE/labels"; }
n_edits()    { grep -c '^issue edit' "$GH_CALLS" || true; }
route()      { set_routing_label owner/demo 48 "$1"; }   # echoes its note, returns rc

REPO=owner/demo

# ── (a) checked-pass -> resume: the observed sequence, now clearing ───────────
reset_gh; set_labels checked-pass
out="$(route resume)"; rc=$?
assert_rc 0 "$rc" "routing \`resume\` over \`checked-pass\` succeeds"
assert_eq "resume" "$(labels_now)" \
  "checked-pass is GONE and resume is present" \
  "set_routing_label must clear the other routing labels — a surviving checked-pass is issue #83."
assert_contains "$out" "applied \`resume\`, cleared \`checked-pass\`" \
  "the helper reports what it cleared, not just what it applied"
assert_eq 1 "$(n_edits)" \
  "the relabel is ONE \`gh issue edit\` (add + remove together)" \
  "Two calls leave a window where the issue is in two courts, or in none."

# ── (b) the mirror direction ─────────────────────────────────────────────────
reset_gh; set_labels resume
out="$(route checked-pass)"
assert_eq "checked-pass" "$(labels_now)" \
  "resume is GONE and checked-pass is present (mirror direction)" \
  "A checker that passes an issue still carrying \`resume\` produces the mirror-image mess."

# ── (c) idempotent: nothing to do -> no write at all ─────────────────────────
reset_gh; set_labels resume
out="$(route resume)"; rc=$?
assert_rc 0 "$rc" "re-routing the label already in place succeeds"
assert_eq "unchanged" "$out" "it reports \`unchanged\` rather than claiming a write"
assert_eq "resume" "$(labels_now)" "the label set is untouched"
assert_eq 0 "$(n_edits)" \
  "an already-correct issue costs ZERO \`gh issue edit\` calls" \
  "ledger-prune.sh's reconciler re-runs every cycle; it must not churn the issue."

# ── (d) clears BOTH others; never touches a non-routing label ────────────────
reset_gh; set_labels checked-pass needs-input hold needs-definition
out="$(route resume)"
assert_eq "hold needs-definition resume" "$(labels_now)" \
  "both other routing labels are cleared; hold/needs-definition survive" \
  "hold/blocked are parking and needs-definition is an intake verdict — not court hand-offs."

# ── (e) fail-soft: rc 1, and the issue left exactly as it was ────────────────
reset_gh; set_labels checked-pass
if out="$(FAKE_EDIT_FAIL=1 route resume 2>/dev/null)"; then rc=0; else rc=1; fi
assert_rc 1 "$rc" "a failing \`gh issue edit\` returns 1"
assert_eq "checked-pass" "$(labels_now)" \
  "a failed edit leaves the issue untouched, not half-relabelled"
err="$(FAKE_EDIT_FAIL=1 route resume 2>&1 >/dev/null || true)"
assert_contains "$err" "could not route" "the failure is reported on stderr, never silent"

reset_gh; set_labels checked-pass
if out="$(route not-a-routing-label 2>/dev/null)"; then rc=0; else rc=1; fi
assert_rc 1 "$rc" "a non-routing label argument is refused"
assert_eq "checked-pass" "$(labels_now)" "…and nothing is written"
assert_eq 0 "$(n_edits)" "…and no \`gh issue edit\` is attempted"

reset_gh; set_labels checked-pass
if out="$(set_routing_label "$REPO" "" resume 2>/dev/null)"; then rc=0; else rc=1; fi
assert_rc 1 "$rc" "a missing issue number is refused"
assert_eq 0 "$(n_edits)" "…with no \`gh issue edit\` attempted"

# `gh` absent from PATH entirely — the offline tier's standing fail-soft case.
reset_gh; set_labels checked-pass
if out="$(PATH=/nonexistent-for-this-test route resume 2>/dev/null)"; then rc=0; else rc=1; fi
assert_rc 1 "$rc" "no \`gh\` on PATH returns 1 rather than aborting the caller"

# ── (f) a failed labels LOOKUP still routes (unconditional form) ─────────────
# The lookup is an optimization (idempotence + only removing what is present). Losing it
# must not strand an unattended recovery on a flaky network: fall back to add + remove
# both others, which is correct whatever the issue currently carries.
reset_gh; set_labels checked-pass
out="$(FAKE_VIEW_FAIL=1 route resume)"; rc=$?
assert_rc 0 "$rc" "a failed labels lookup does not block the route"
assert_eq "resume" "$(labels_now)" \
  "the unconditional fallback still clears the stale checked-pass" \
  "Bailing here would make a flaky network silently skip the routing act."
assert_contains "$(cat "$GH_CALLS")" "--remove-label" \
  "the fallback issues the removes unconditionally"

# ── (g) end to end through the real ledger-prune.sh ──────────────────────────
reset_gh
cat >"$SB/projects/demo.yml" <<YML
repo: $REPO
data_root: $SB/data
worktrees_dir: $SB/worktrees
YML
WLOG="$SB/logs/demo-issue-48.log"; : >"$WLOG"
# The ledger is REWRITTEN by each run (the entry is pruned), so re-seed it per case.
run_prune() {
  cat >"$SB/ledger.md" <<LEDGER
- #48 | $REPO | issue-48 | $WLOG | pid - | dispatched 2026-09-18T08:00:00Z | status interrupted-ratelimit
LEDGER
  FAKE_ISSUE_STATE=CLOSED LEDGER="$SB/ledger.md" "$SB/bin/ledger-prune.sh" >/dev/null 2>&1 || true
}

# (g1) the cosmetic `resume` relabel goes through the helper, so it carries the removes.
#      NOTE this path cannot be exercised with a stale `checked-pass` already in place:
#      handle_no_clean_finish early-returns on {needs-input, checked-pass} — one more
#      backstop the stale label suppresses, which is why #83 fixes the WRITE sites rather
#      than teaching each reader to distrust the label.
set_labels
run_prune
assert_contains " $(labels_now) " " resume " \
  "ledger-prune's cosmetic relabel still applies \`resume\`"
assert_matches "$(grep '^issue edit' "$GH_CALLS" | head -1)" '\-\-add-label resume.*--remove-label' \
  "…and it does so through set_routing_label (the removes ride along)" \
  "relabel_resume must not go back to a bare gh --add-label (issue #83)."

# (g2) the WORKER_LIMIT escalation clears a stale `resume` as it applies `needs-input`.
#      Same collision, opposite direction: an issue left in the worker's court while the
#      loop hands it to the operator would sit in both at once.
reset_gh; set_labels resume
FAKE_INTERRUPTED=4 run_prune
assert_contains " $(labels_now) " " needs-input " \
  "the WORKER_LIMIT escalation applies needs-input" \
  "4 trailing **Worker interrupted: comments must trip WORKER_LIMIT (default 4)."
assert_not_contains " $(labels_now) " " resume " \
  "…and CLEARS the resume it was escalating out of" \
  "escalate_needs_input must route through set_routing_label, not a bare --add-label."

# ── (h) the invariant's blast radius, checked as text ────────────────────────
# Criterion: set_routing_label is the ONLY thing in bin/ that writes a routing label.
# Read the real tree, not the sandbox copies.
stray="$(grep -rn -- '--add-label' "$REPO_ROOT/bin/" \
          | grep -E 'checked-pass|[^-]resume|needs-input' \
          | grep -v 'dispatch-common.sh' || true)"
assert_eq "" "$stray" \
  "no routing-label \`--add-label\` in bin/ outside set_routing_label" \
  "Every routing-label write must go through the helper (issue #83): $stray"

brief="$(cat "$REPO_ROOT/briefs/checker-brief.md")"
for lab in checked-pass resume needs-input; do
  line="$(grep -A1 -- "--add-label $lab" <<<"$brief" | tr '\n' ' ')"
  assert_contains "$line" "--remove-label" \
    "checker-brief's \`$lab\` route emits the clearing form" \
    "The checker applies its own label in its own session — the brief is the only place this fix can live for it."
done
