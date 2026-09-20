#!/usr/bin/env bash
# test-verdict-sweep.sh (offline) — ledger-prune.sh's phase-2 verdict sweep, specifically
# the RETIREMENT added by issue #85 and the `--dry-run` that guards it.
#
# WHY THIS EXISTS. Nothing ever removed a verdict file, so the unowned set grew ~45/month
# against a fixed `VERDICT_SWEEP_LIMIT=25` window: every cycle printed a truncation warning
# whose number only climbed, on the SAME stderr channel as the genuine `⚠ UNROUTED VERDICT`
# finding. The sweep already knew a PR was closed and threw that away. Now it retires the
# file — which makes this a pass that MOVES state on an unattended cron, so every edge of
# the selection rule needs a net under it.
#
# Hermetic: a throwaway sandbox ORCH and a `gh` shim driven by env vars. No network, no
# real logs/, nothing dispatched. Cases, matching the issue's acceptance criteria:
#   (a) unowned + PR closed  -> retired into logs/archive/, WITH its `.prev.json` sibling
#   (b) unowned + PR open + label present -> left in place, reported clean
#   (c) unowned + PR open + label MISSING -> still produces `⚠ UNROUTED VERDICT`, not retired
#   (d) ledger-OWNED file -> never touched, whatever the PR state
#   (e) a failing / unparseable `gh` -> retires nothing (uncertain network, silent + retry)
#   (f) `--dry-run` -> filesystem byte-identical, and the SELECTION it reports is
#       line-for-line the real run's once the `[dry-run] ` tag is stripped
#   (g) the reworded truncation note: it names the ordering, and a drained backlog is silent
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
ARCHIVE="$SB/logs/archive"

cat >"$SB/projects/demo.yml" <<YML
repo: owner/demo
data_root: $SB/data
worktrees_dir: $SB/worktrees
YML

# --- shims --------------------------------------------------------------------
SHIMS="$(sandbox_tmp)"
export GH_STATE="$SHIMS/state"; mkdir -p "$GH_STATE"

# `gh` shim. FAKE_PR_STATE drives `pr view --json state` (the retirement's gate);
# $GH_STATE/labels is the label set `issue view --json labels` reports back.
# FAKE_GH_FAIL=1 makes every call exit nonzero — the uncertain-network case.
# FAKE_GH_GARBAGE=1 makes `pr view` emit unparseable bytes on a ZERO exit, which is the
# nastier half of the same case: rc says success, jq yields empty, and the guard has to be
# reading the parsed STATE rather than the exit code.
cat >"$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_GH_FAIL:-}" ] && exit 1
LABELS="$GH_STATE/labels"
case "$1 ${2:-}" in
  "pr view")
    if [ -n "${FAKE_GH_GARBAGE:-}" ]; then echo 'not json at all'; exit 0; fi
    printf '{"state":"%s"}\n' "${FAKE_PR_STATE:-OPEN}" ;;
  "issue view")
    case " $* " in
      *" --json labels "*)
        python3 - "$LABELS" <<'PY'
import json, sys
try:    names = [l.strip() for l in open(sys.argv[1]) if l.strip()]
except OSError: names = []
print(json.dumps({"labels": [{"name": n} for n in names]}))
PY
        ;;
      *" --json state "*) printf '{"state":"%s"}\n' "${FAKE_ISSUE_STATE:-OPEN}" ;;
      *) echo '{}' ;;
    esac ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$SHIMS/gh"
# tmux always reports "no session" so no reconcile rung reaches a real liveness probe.
cat >"$SHIMS/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in has-session) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$SHIMS/tmux"
export PATH="$SHIMS:$PATH"

# --- fixtures -----------------------------------------------------------------
LED="$SB/ledger.md"
VERDICT="$SB/logs/demo-pr-64-verdict.json"
PREV="$SB/logs/demo-pr-64-verdict.prev.json"

# seed [with-prev] — rebuild logs/ from scratch with one unowned verdict file. `find
# -delete` rather than a recursive force-remove: the suite never needs one, and the host
# deny-hook blocks it outright.
seed() {
  find "$SB/logs" -mindepth 1 -depth -delete 2>/dev/null || true
  mkdir -p "$SB/logs"
  cat >"$VERDICT" <<'JSON'
{"pr": 64, "issue": 48, "verdict": "pass", "findings": [],
 "evidence": ["./bin/test.sh"], "failure_class": "none", "mutation_delta": ""}
JSON
  if [ "${1:-}" = "with-prev" ]; then cp "$VERDICT" "$PREV"; fi
  : >"$LED"
  rm -f "$GH_STATE/labels"
  return 0
}
run() { LEDGER="$LED" "$LP" "$@" 2>&1; }
# A stable, order-independent fingerprint of logs/ — names + sizes, nothing timestamped.
tree_fp() { (cd "$SB" && find logs -type f | LC_ALL=C sort | while read -r f; do
              printf '%s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')"; done); }

# ── (a) unowned + closed PR -> retired, sibling included ─────────────────────
seed with-prev
out_a="$(FAKE_PR_STATE=MERGED run)"
assert_file_absent "$VERDICT" \
  "a swept unowned verdict on a closed/merged PR is retired out of logs/" \
  "Issue #85: the sweep must drain the unowned set, not only count it."
assert_file_present "$ARCHIVE/$(basename "$VERDICT")" \
  "the retired verdict lands in logs/archive/ (a move, not a delete)" \
  "Retirement is deliberately reversible — see the block comment in bin/ledger-prune.sh."
assert_file_absent "$PREV" \
  "the rotated .prev.json sibling is retired with its canonical file" \
  "Otherwise the .prev slots accumulate after their canonical file is gone."
assert_file_present "$ARCHIVE/$(basename "$PREV")" \
  "the retired sibling lands in logs/archive/ too" \
  "Both halves of the pair move together or the archive is misleading."
assert_contains "$out_a" "retire $(basename "$VERDICT") — owner/demo#64 is MERGED" \
  "the retirement names the file and why it was retired" \
  "An unattended pass that moves files must say which, and on what grounds."
assert_contains "$out_a" "verdict sweep retired 2 closed-PR verdict file(s)" \
  "the sweep summarises how many files it retired" \
  "The count is the drain rate the reworded warning promises."
assert_not_contains "$out_a" "UNROUTED VERDICT" \
  "a closed PR's verdict is retired, not reported as unrouted" \
  "A merged PR's verdict is moot — reporting it is the noise this issue is about."

# A second run has nothing left to do, and must not resurrect or re-report anything.
out_a2="$(FAKE_PR_STATE=MERGED run)"
assert_not_contains "$out_a2" "retire " \
  "a re-run retires nothing (the set is drained)" \
  "Retirement must be a one-way drain, not a per-cycle event."
assert_file_present "$ARCHIVE/$(basename "$VERDICT")" \
  "the archived file is left alone by later runs" \
  "logs/archive/ is out of the sweep's glob — it must never be re-swept."

# ── (b) unowned + OPEN PR whose label landed -> left alone, quiet ────────────
seed
printf 'checked-pass\n' >"$GH_STATE/labels"        # the outcome DID land
out_b="$(FAKE_PR_STATE=OPEN run)"
assert_file_present "$VERDICT" \
  "an OPEN PR's verdict file is never retired" \
  "Open-PR verdicts are the small bounded set the sweep exists to keep watching."
assert_not_contains "$out_b" "UNROUTED VERDICT" \
  "an open PR whose label already landed is reported clean" \
  "Every normally-finished checker leaves a verdict behind; only unrouted ones are findings."
assert_not_contains "$out_b" "retire " \
  "nothing is retired on the clean open-PR path" \
  "The retirement gate is a confirmed non-OPEN state, nothing else."

# ── (c) unowned + OPEN PR, label MISSING -> the real finding still fires ─────
seed
out_c="$(FAKE_PR_STATE=OPEN run)"
assert_contains "$out_c" "UNROUTED VERDICT" \
  "an open PR missing its routing label still produces the UNROUTED VERDICT finding" \
  "This is the safety channel the whole sweep exists for — retirement must not shadow it."
assert_contains "$out_c" "carries no \`checked-pass\`" \
  "the finding still names the label that never landed" \
  "The warning has to stay actionable without opening the JSON."
assert_file_present "$VERDICT" \
  "the unrouted file is left on disk for the operator to act on" \
  "Retiring the one file a human still has to read would be the worst possible bug here."

# ── (d) a ledger-OWNED verdict file is never touched ────────────────────────
seed
cat >"$LED" <<LEDGER
- check pr#64 | owner/demo | issue-48 | $SB/logs/demo-pr-64.log | pid $$ | dispatched 2026-08-04T18:34:34Z | status dispatched
LEDGER
: >"$SB/logs/demo-pr-64.log"
out_d="$(FAKE_PR_STATE=MERGED run)"
assert_file_present "$VERDICT" \
  "a verdict file a ledger entry owns is never retired, even on a merged PR" \
  "The sweep's safety argument is that it only ever sees files nothing else can be reading."
assert_not_contains "$out_d" "retire " \
  "an owned file is not even reported as retirable" \
  "reconcile_dead_dispatches and watch-dispatch.sh read owned files."

# ── (e) a failing / unparseable gh retires nothing ──────────────────────────
seed
out_e="$(FAKE_GH_FAIL=1 run)"
assert_file_present "$VERDICT" \
  "a failing \`gh\` retires nothing" \
  "An uncertain network is not a closed PR — it stays silent-and-retry, as before."
assert_not_contains "$out_e" "retire " \
  "a failing \`gh\` does not even claim a retirement" \
  "Issue #85 criterion: only a SUCCESSFUL non-OPEN lookup is grounds for retirement."

seed
out_e2="$(FAKE_GH_GARBAGE=1 run)"
assert_file_present "$VERDICT" \
  "a zero-exit \`gh\` returning unparseable JSON retires nothing" \
  "The gate must read the parsed state, not the exit code — empty state means unknown."
assert_not_contains "$out_e2" "retire " \
  "unparseable \`gh\` output claims no retirement either" \
  "Two identically-broken reads of 'not OPEN' is how a safe rule turns unsafe."

# ── (f) --dry-run: nothing moves, and the selection matches the real run ────
seed with-prev
FP_BEFORE="$(tree_fp)"
out_dry="$(FAKE_PR_STATE=CLOSED run --dry-run)"
assert_eq "$FP_BEFORE" "$(tree_fp)" \
  "--dry-run leaves logs/ byte-identical" \
  "A dry run that moves a file is worse than no dry run at all."
assert_file_absent "$ARCHIVE" \
  "--dry-run does not even create logs/archive/" \
  "Plan-only must leave no trace on the filesystem."
out_real="$(FAKE_PR_STATE=CLOSED run)"
# Strip the tag from the dry lines; the two selections must be line-for-line identical.
sel_dry="$(printf '%s\n' "$out_dry"  | grep -F 'retire ' | sed 's/\[dry-run\] //')"
sel_real="$(printf '%s\n' "$out_real" | grep -F 'retire ')"
assert_ne "" "$sel_dry" \
  "--dry-run reports what it would retire" \
  "Criterion: the dry run must report the selection, not just stay silent."
assert_eq "$sel_dry" "$sel_real" \
  "the dry-run selection is byte-for-byte the real run's once the [dry-run] tag is stripped" \
  "If the two selections can differ, the dry run is not a preview of anything."
assert_contains "$out_dry" "[dry-run]" \
  "dry-run output is tagged as such" \
  "An untagged plan reads as a report of work already done."

# The dry run must also not rewrite the LEDGER (phase 3) — script-wide, not sweep-only.
seed
cat >"$LED" <<LEDGER
- #48 | owner/demo | issue-48 | $SB/logs/demo-issue-48.log | pid 99999999 | dispatched 2026-08-04T18:34:34Z | status interrupted-budget
LEDGER
LED_BEFORE="$(cat "$LED")"
out_dryled="$(FAKE_ISSUE_STATE=CLOSED run --dry-run)"
assert_eq "$LED_BEFORE" "$(cat "$LED")" \
  "--dry-run leaves the ledger unchanged" \
  "Script-wide dry run: phase 3 must not rewrite the ledger either."
assert_contains "$out_dryled" "would prune:" \
  "--dry-run reports the lines it would prune" \
  "Plan-only still has to say what the real run would do."

# ── (g) the reworded truncation note ────────────────────────────────────────
# Three unowned files against a limit of 1: one is checked, two are skipped. `gh` is made
# to fail so the checked one is neither retired nor reported — the note is isolated.
seed
for n in 65 66; do
  sed "s/\"pr\": 64/\"pr\": $n/" "$VERDICT" >"$SB/logs/demo-pr-$n-verdict.json"
done
out_g="$(VERDICT_SWEEP_LIMIT=1 FAKE_GH_FAIL=1 run)"
assert_contains "$out_g" "2 older one(s) not checked this cycle" \
  "the truncation note reports how many files went unchecked" \
  "Issue #85 criterion: the note must still report the count."
assert_contains "$out_g" "newest-first, so the untouched files are the OLDEST" \
  "the note states the ordering, so the reader knows WHICH files went unchecked" \
  "Without it the line reads as 'coverage was lost' — a standing false alarm."
assert_contains "$out_g" "drains at up to 1/cycle" \
  "the note says the backlog now drains rather than growing forever" \
  "That is the fact that makes the warning self-liquidating instead of permanent."

# A backlog that fits in the window says nothing at all.
out_g2="$(VERDICT_SWEEP_LIMIT=25 FAKE_GH_FAIL=1 run)"
assert_not_contains "$out_g2" "not checked this cycle" \
  "a cycle whose backlog fits in the window emits no truncation note" \
  "Issue #85 criterion: a drained backlog must be silent."

# ── unknown flags are refused rather than ignored ───────────────────────────
set +e
out_bad="$(LEDGER="$LED" "$LP" --no-such-flag 2>&1)"; rc_bad=$?
set -e
assert_rc 2 "$rc_bad" \
  "an unknown argument exits 2 rather than running a full real pass" \
  "A typo'd flag must never silently become a live run."
assert_contains "$out_bad" "unknown argument" \
  "the refusal names the offending argument" \
  "Fail loud, with the usage line."
