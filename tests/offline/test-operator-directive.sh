#!/usr/bin/env bash
# test-operator-directive.sh (OFFLINE) — the `**Operator directive:` channel (issue #77):
# every issue comment led by `**Operator directive:` is injected VERBATIM, oldest first,
# into the worker brief's {{OPERATOR_DIRECTIVES}} token by bin/launch-worker.sh.
#
# The bug this pins: post-review operator feedback that EXTENDS an issue used to reach the
# worker only as one comment among many, while the brief framed the issue body as the
# contract and said "don't expand it" — so the instruction read as scope creep to decline.
# Injection is what makes it unmissable, so the properties that matter are:
#
#   1. Injected — one directive appears verbatim inside --append-system-prompt, and the
#      dry-run reports the count.
#   2. Ordered  — several directives appear oldest-first (a later one refines an earlier
#      one, so a reversed order silently changes the instruction).
#   3. Fail soft — gh failing, gh returning garbage, and gh ABSENT all render the same
#      fixed no-directives line, exit 0, and leave the dispatch otherwise untouched. The
#      offline tier itself runs with no network, so this is not a hypothetical path.
#   4. Byte-identity — with zero directives the dry-run info block is EXACTLY what it was
#      before this key existed, plus the one fixed `directives` line. Pinned as whole-block
#      equality against a literal built here (the #74/#75 discipline), not as a `contains`:
#      a `contains` would pass even if a stray line leaked in.
#
# ASSERTING "VERBATIM" THROUGH `printf '%q'`. The dry-run prints the assembled command with
# `printf '  %q'`, and the brief contains newlines, so bash renders that argument in
# `$'…'` form: newlines become `\n`, but ordinary ASCII — spaces included — is left
# literal. A plain-ASCII, single-line directive body therefore appears as a contiguous
# substring and can be grepped for directly. Non-ASCII would NOT (bash 3.2 escapes it
# octally, e.g. an em-dash becomes \342\200\224), which is why every fixture directive
# below is deliberately plain ASCII.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 \
  || { skip "python3 not installed — skipping operator-directive injection"; exit 0; }

# The budget/fallback defaults are pinned in the byte-identity literal below, so an
# inherited WORKER_BUDGET from the caller's environment must not leak into the run.
unset WORKER_BUDGET || true

SLUG="directive-demo"
REPO="test-operator/$SLUG"
ISSUE=77

# --- shared sandbox: a throwaway ORCH the launcher resolves as its repo root --------
SB="$(new_sandbox)"
write_filled_conf "$SB"
sandbox_copy_script "$SB" launch-worker
sandbox_copy_script "$SB" dispatch-common
sandbox_copy_script "$SB" config-common
cp -R "$REPO_ROOT/host" "$SB/host"
cp -R "$REPO_ROOT/templates" "$SB/templates"
cp "$REPO_ROOT/briefs/worker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-worker.sh"

# A code-only manifest (raw_resolved == working_clone), so nothing here implies real data.
CLONE="$(sandbox_tmp)"; WTS="$(sandbox_tmp)"
cat >"$SB/projects/$SLUG.yml" <<YML
repo: $REPO
working_clone: $CLONE
worktrees_dir: $WTS
data_root: $CLONE
raw_resolved: $CLONE
output_paths:
  - data/results/
YML

# --- the brief must actually carry the token, or every assertion below is vacuous ---
assert_contains "$(cat "$REPO_ROOT/briefs/worker-brief.md")" '{{OPERATOR_DIRECTIVES}}' \
  "briefs/worker-brief.md carries the {{OPERATOR_DIRECTIVES}} token" \
  "Without the token the launcher has nowhere to substitute directives and they never reach the worker (#77)."
assert_not_contains "$(cat "$REPO_ROOT/briefs/worker-brief.md")" \
  "Stay scoped to the issue; don't expand it." \
  "the bare 'don't expand it' line is gone from the worker brief" \
  "That line told the worker to REFUSE exactly the scope extension an operator directive is (#77); it must be replaced with wording that makes a directive in scope by construction."

# --- gh shims --------------------------------------------------------------------
# ok:      serves $GH_COMMENTS for `gh issue view … --json comments`
# fail:    exits 1 (unauthenticated / rate-limited / offline)
# garbage: exits 0 with output that is not JSON at all
SHIM_OK="$(sandbox_tmp)"
cat >"$SHIM_OK/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then cat "$GH_COMMENTS"; exit 0; fi
echo '{}'
SH
SHIM_FAIL="$(sandbox_tmp)"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SHIM_FAIL/gh"
SHIM_GARBAGE="$(sandbox_tmp)"
printf '#!/usr/bin/env bash\nprintf "<!DOCTYPE html> not json at all"\n' >"$SHIM_GARBAGE/gh"
chmod +x "$SHIM_OK/gh" "$SHIM_FAIL/gh" "$SHIM_GARBAGE/gh"

COMMENTS="$SB/comments.json"

# write_comments BODY... — the shim's comment history, oldest first (gh's own order).
write_comments() {
  python3 - "$COMMENTS" "$@" <<'PY'
import json, sys
json.dump({"comments": [{"body": b} for b in sys.argv[2:]]}, open(sys.argv[1], "w"))
PY
}

# dry SHIMDIR -> the launcher's whole --dry-run output (rc captured by the caller)
dry() {
  PATH="$1:$PATH" GH_COMMENTS="$COMMENTS" \
    "$SB/bin/launch-worker.sh" "$SLUG" "$ISSUE" --dry-run 2>&1
}

# ascii TEXT — the same text with every non-ASCII byte dropped.
#
# LOAD-BEARING, not tidiness. The assembled command is printed by `printf '  %q'`, and on
# the brief (which contains em-dashes) bash 3.2 emits a MIX of raw and octal-escaped bytes
# — i.e. a string that is not valid UTF-8. Under a UTF-8 locale `grep`/`cut`/`sed` abort on
# it with "Illegal byte sequence" and exit nonzero, so `assert_contains` reports a needle
# that is plainly present as MISSING. (tests/offline/test-extra-read-resolved.sh documents
# the same trap from the other direction.) Every needle asserted below is ASCII, so the
# squash is lossless for our purposes.
ascii() { LC_ALL=C tr -cd '\11\12\15\40-\176' <<<"$1"; }

# info_block TEXT — just the `# DRY RUN …` header block, up to the assembled command.
# LC_ALL=C for the reason above; the block itself is compared with `=`, which is
# byte-exact and locale-free, so its own em-dash survives the round trip.
info_block() { LC_ALL=C sed -n '/^# DRY RUN/,/^# Assembled command:/p' <<<"$1"; }

D1='**Operator directive: also report the 2019 cohort, split by county.'
D2='**Operator directive: drop the top 1 percent of the exposure distribution.'
D3='**Operator directive: on reflection, winsorize at 99 percent instead of dropping.'
OTHER='Just a normal milestone comment, no lead at all.'
NEARMISS='Operator directive: missing the bold lead, so it must NOT be injected.'
# The fixed no-directives line, as an ASCII-only needle: ascii() above drops the line's
# em-dash, so the needle must not contain one either.
NO_DIR_LINE='this issue carries no `**Operator directive:` comment.'

# ===================================================================================
# (1) ONE directive — injected verbatim, counted on its own dry-run line.
# ===================================================================================
write_comments "$OTHER" "$D1"
rc=0; out="$(dry "$SHIM_OK")" || rc=$?
assert_rc 0 "$rc" "launch-worker --dry-run exits 0 with one directive present"
out="$(ascii "$out")"
assert_contains "$out" "$D1" \
  "the directive comment body reaches --append-system-prompt VERBATIM" \
  "bin/launch-worker.sh must substitute every \`**Operator directive:\` comment into the brief's {{OPERATOR_DIRECTIVES}} token (#77)."
assert_contains "$out" "#   directives    : 1" \
  "the dry-run reports the injected directive count on its own line" \
  "The count line is how an operator confirms the channel fired without reading the whole brief."
assert_not_contains "$out" "$NO_DIR_LINE" \
  "the no-directives line is absent when a directive exists"
assert_not_contains "$out" "$OTHER" \
  "an ordinary comment with no lead is NOT injected" \
  "The lead is the whole filter — injecting every comment would drown the directive it exists to surface."

# A near-miss lead (no `**`) must not match: the convention is an exact, greppable lead,
# and a fuzzy match would inject stray prose into the contract.
write_comments "$NEARMISS"
out="$(ascii "$(dry "$SHIM_OK")")"
assert_contains "$out" "#   directives    : 0" \
  "a comment missing the exact \`**Operator directive:\` lead is not injected"
assert_contains "$out" "$NO_DIR_LINE" \
  "the near-miss case renders the fixed no-directives line"

# ===================================================================================
# (2) SEVERAL directives — oldest first, order preserved.
# ===================================================================================
write_comments "$D1" "$OTHER" "$D2" "$OTHER" "$D3"
out="$(ascii "$(dry "$SHIM_OK")")"
assert_contains "$out" "#   directives    : 3" \
  "all three directives are counted, interleaved comments ignored"
# Compare the ORDER the three distinctive tails appear in against the posting order. A
# reversed injection changes the instruction (D3 refines D2), so order is behavior.
order="$(LC_ALL=C grep -o 'the 2019 cohort\|top 1 percent\|winsorize at 99' <<<"$out" | tr '\n' ' ')"
assert_eq "the 2019 cohort top 1 percent winsorize at 99 " "$order" \
  "directives are injected oldest-first, in posting order" \
  "gh lists comments oldest-first and the launcher must preserve that — a later directive refines an earlier one (#77)."

# ===================================================================================
# (3) FAIL SOFT — a failing gh, a garbage-returning gh, and no gh at all.
# ===================================================================================
write_comments "$D1" "$D2"      # present, but unreachable through these shims
for shim_name in FAIL GARBAGE; do
  eval "shim=\$SHIM_$shim_name"
  rc=0; out="$(dry "$shim")" || rc=$?
  out="$(ascii "$out")"
  assert_rc 0 "$rc" "a $shim_name gh leaves launch-worker --dry-run exiting 0" \
    "The directive fetch must never abort a dispatch — the whole point of the fail-soft contract (#77)."
  assert_contains "$out" "$NO_DIR_LINE" \
    "a $shim_name gh renders the fixed no-directives line in the brief" \
    "A failed fetch must degrade to one fixed line, not to an empty or half-rendered section."
  assert_contains "$out" "#   directives    : 0" \
    "a $shim_name gh reports 0 directives on the dry-run line"
  assert_contains "$out" "# Assembled command:" \
    "a $shim_name gh still assembles the full command" \
    "Dispatch must be unaffected by the fetch failing."
done

# gh genuinely ABSENT (python3's subprocess raises FileNotFoundError rather than
# returning nonzero — a different code path from the failing shim above). /usr/bin:/bin
# has the coreutils/python3/git the launcher needs but not Homebrew's gh; if that is not
# true on this host the case is skipped rather than silently testing nothing.
BAREPATH="/usr/bin:/bin"
if PATH="$BAREPATH" command -v gh >/dev/null 2>&1; then
  skip "gh resolves under $BAREPATH — skipping the gh-absent case (the failing-shim case covers the rest)"
elif ! PATH="$BAREPATH" command -v python3 >/dev/null 2>&1; then
  skip "no python3 under $BAREPATH — skipping the gh-absent case"
else
  rc=0
  out="$(PATH="$BAREPATH" GH_COMMENTS="$COMMENTS" \
           "$SB/bin/launch-worker.sh" "$SLUG" "$ISSUE" --dry-run 2>&1)" || rc=$?
  out="$(ascii "$out")"
  assert_rc 0 "$rc" "gh ABSENT from PATH leaves launch-worker --dry-run exiting 0" \
    "A host without gh must still be able to assemble (and dispatch) a worker."
  assert_contains "$out" "$NO_DIR_LINE" \
    "gh ABSENT renders the fixed no-directives line"
  assert_contains "$out" "#   directives    : 0" \
    "gh ABSENT reports 0 directives on the dry-run line"
fi

# ===================================================================================
# (4) BYTE-IDENTITY — zero directives adds the one fixed line and nothing else.
# ===================================================================================
write_comments "$OTHER"
zero_out="$(dry "$SHIM_OK")"

# The launcher resolves its own root with `cd … && pwd`, which normalizes the `//` mktemp
# leaves when TMPDIR ends in a slash — normalize here too, or this compares cosmetics.
SBN="$(cd "$SB" && pwd)"
want="$(cat <<EXPECTED
# DRY RUN — guarded worker for $REPO issue #$ISSUE
#   manifest      : $SBN/projects/$SLUG.yml
#   working clone : $CLONE
#   worktree      : $WTS/issue-$ISSUE   (branch: issue-$ISSUE)
#   raw (RO)      : $CLONE   <- --add-dir + deny-hook protected
#   outputs       : data/results/
#   directives    : 0   <- \`**Operator directive:\` issue comments injected into the brief (#77)
#   tools         : Agent DISABLED (no subagents: delegation escapes brief + Stop hook)
#   deny-hook     : $SBN/host/hooks/raw-data-guard.py   <- injected via --settings (PreToolUse)
#   stop-hook     : $SBN/host/hooks/worker-stop-guard.sh $ISSUE $REPO   <- injected via --settings (Stop): exit-contract guard
#   budget cap    : \$10.00   fallback: claude-sonnet-4-6
#   log           : $SBN/logs/$SLUG-issue-$ISSUE.log
#
# Assembled command:
EXPECTED
)"
assert_eq "$want" "$(info_block "$zero_out")" \
  "zero directives: the dry-run info block is the pre-#77 block plus ONE fixed line" \
  "Whole-block equality is the byte-identity contract (#74/#75 discipline): the directive channel may add exactly the \`directives\` line and must not perturb, reorder or drop anything else."

# The same run through a failing gh must be byte-identical to the zero-directive run:
# "no directives" and "could not find out" render the same, so a dispatch's prompt never
# depends on whether the network happened to be up.
assert_eq "$zero_out" "$(dry "$SHIM_FAIL")" \
  "a failing gh produces output byte-identical to a zero-directive fetch" \
  "A fetch failure must be indistinguishable from 'no directives' — otherwise the worker's prompt silently varies with network weather."

# And the --add-dir vector is untouched: this key adds prompt text, never read scope.
add_dirs() {
  LC_ALL=C sed -n '/^# Assembled command:/,$p' <<<"$1" \
    | LC_ALL=C grep -o -- '--add-dir  *[^ ]*' \
    | LC_ALL=C sed -E 's/^--add-dir[[:space:]]+//'
}
write_comments "$D1" "$D2" "$D3"
assert_eq "$(printf '%s\n%s' "$WTS/issue-$ISSUE" "$CLONE")" "$(add_dirs "$(dry "$SHIM_OK")")" \
  "three injected directives leave the --add-dir vector exactly worktree + raw" \
  "The directive channel is prompt text only; it must never widen a worker's filesystem scope."

# ===================================================================================
# (5) CAPS NON-REGRESSION — the new lead must stay out of both round-counting lists.
# ===================================================================================
# A directive is the operator REPLYING, which already resets WORKER_LIMIT /
# WORKER_WAIT_LIMIT like any intervening comment (asserted end-to-end in
# test-ledger-prune.sh). Counting it as a round would penalize the operator for asking.
assert_not_contains "$(cat "$REPO_ROOT/bin/ledger-prune.sh")" "Operator directive" \
  "bin/ledger-prune.sh's NO_FINISH_LEADS does not know the directive lead" \
  "A directive comment must RESET the worker counters as a normal reply, never count as a failed round (#77)."
assert_not_contains "$(cat "$REPO_ROOT/bin/dispatch-common.sh")" "Operator directive" \
  "bin/dispatch-common.sh's CHECKER_ROUND_LEADS does not know the directive lead" \
  "Checker rounds count checker output; an operator instruction is not a checker round (#77)."

# ===================================================================================
# (6) THE PROTOCOL DOCS — the convention only works if all four roles describe it the
# same way. These are the four places a role learns it exists.
# ===================================================================================
assert_contains "$(cat "$REPO_ROOT/briefs/checker-brief.md")" "Operator directive" \
  "briefs/checker-brief.md describes the directive convention" \
  "The checker must verify a (directive) criterion and bounce an untranscribed directive (#77)."
assert_contains "$(cat "$REPO_ROOT/briefs/checker-brief.md")" "(directive)" \
  "briefs/checker-brief.md names the '- [ ] (directive)' body marker"
assert_contains "$(cat "$REPO_ROOT/briefs/orchestrator-interactive-brief.md")" "Operator directive" \
  "briefs/orchestrator-interactive-brief.md's hand-back path emits the directive comment" \
  "The write side of the convention lives in the interactive orchestrator's hand-back path (#77)."
assert_contains "$(cat "$REPO_ROOT/briefs/orchestrator-interactive-brief.md")" "(directive)" \
  "the hand-back path also emits the '- [ ] (directive)' body append" \
  "Both halves are required: the comment alone leaves the body contract unaware of the extension."
assert_contains "$(cat "$REPO_ROOT/templates/pr-results-summary.md")" "Operator directive" \
  "templates/pr-results-summary.md's Goal section covers operator-directed extensions" \
  "Otherwise the PR summary understates what the PR contains (#77)."
assert_contains "$(cat "$REPO_ROOT/design.md")" "Operator directive" \
  "design.md records the convention"
