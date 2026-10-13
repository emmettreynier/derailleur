#!/usr/bin/env bash
# test-orchestrate-command.sh (OFFLINE) — the /orchestrate command source and its shared
# brief carry the #91 contract: cwd-default scope, auto-chaining after ONE "go", the
# stop-and-ask list, the round-cap gate — and an UNCHANGED merge gate.
#
# Source-level, because the command is prose the harness renders; what this pins is
# that the load-bearing lines exist (and that the merge tool was not quietly granted).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"

CMD_FILE="$REPO_ROOT/templates/orchestrate.command.md"
BRIEF_FILE="$REPO_ROOT/briefs/orchestrator-interactive-brief.md"
CMD="$(cat "$CMD_FILE")"
BRIEF="$(cat "$BRIEF_FILE")"
ALLOWED="$(grep -m1 '^allowed-tools:' "$CMD_FILE")"
DESC="$(grep -m1 '^description:' "$CMD_FILE")"
HINT="$(grep -m1 '^argument-hint:' "$CMD_FILE")"

# --- frontmatter -------------------------------------------------------------------
assert_not_contains "$ALLOWED" "gh pr merge" \
  "gh pr merge is NOT in allowed-tools" \
  "The merge must still surface a harness permission prompt (the second confirmation)."
assert_contains "$ALLOWED" "Bash(dr round-cap:*)" "the round-cap check is in allowed-tools"
assert_contains "$DESC" "you choose what gets worked on and whether it merges" \
  "description carries the new line"
for w in "this repo" "all = whole board" "that repo"; do
  assert_contains "$HINT" "$w" "argument-hint documents '$w'"
done

# --- scope: all argument handling lives in board-digest.sh -------------------------
assert_contains "$CMD" '!`dr board-digest --here $ARGUMENTS`' \
  "the digest is injected via --here, passing \$ARGUMENTS through untouched"
assert_eq 1 "$(grep -c 'dr board-digest' <<<"$(grep '^!' "$CMD_FILE")")" \
  "exactly one digest injection (no scope branching in the command body)"

# --- opening batch still proposed; then chain without a further go ------------------
for f in CMD BRIEF; do
  txt="${!f}"
  assert_contains "$txt" 'dr round-cap worker <slug> <issue#>' "$f: round-cap before a follow-up worker"
  assert_contains "$txt" 'dr round-cap checker <slug> <pr#>' "$f: round-cap before a follow-up checker"
done
assert_contains "$CMD" 'wait for an explicit "go"' "command: the opening batch waits for an explicit go"
assert_contains "$BRIEF" 'Nothing is dispatched before that first "go"' "brief: nothing is dispatched before the first go"
assert_contains "$CMD" 'no further "go"' "command: follow-ups need no further go"
assert_contains "$BRIEF" 'without asking for another "go"' "brief: follow-ups need no further go"
assert_contains "$BRIEF" "Approved items only" "brief: chaining is limited to approved items"
assert_contains "$BRIEF" 'before EVERY follow-up dispatch' "brief: the check is required before every follow-up"

# --- the stop list (decision 3) ---------------------------------------------------
STOPS="$(awk '/^### Stop and ask/{on=1} on&&/^## /{exit} on' "$BRIEF_FILE")"
for s in '`needs-input`, `needs-definition`, `hold` or `blocked` label' \
         'a checker returns a `blocked` verdict' \
         '`dr round-cap` refuses' \
         '`interrupted-*` or `incomplete-*`' \
         '**except `incomplete-waiting`**' \
         '`CONFLICTING`' \
         'exits nonzero'; do
  assert_contains "$STOPS" "$s" "brief stop list: $s"
done
assert_contains "$STOPS" "**not** apply \`needs-input\` or any other routing label" \
  "brief: a tripped cap is stop-and-ask, never a label write"
assert_contains "$BRIEF" '**`incomplete-waiting` keeps watching.**' \
  "brief: incomplete-waiting keeps watching"

# --- merge gate unchanged in substance ---------------------------------------------
assert_contains "$BRIEF" "## Merging on explicit instruction (the ONE path — never on your own initiative)" \
  "brief keeps the merge section"
assert_contains "$BRIEF" "gh pr merge <n> -R <owner/repo> --squash --delete-branch" \
  "…with its command form"
assert_contains "$BRIEF" '(a "go" authorizes launches, never a merge)' \
  "…and a go still never authorizes a merge"

# --- path/token hygiene ------------------------------------------------------------
assert_eq "" "$(grep -n '{{' "$BRIEF_FILE" || true)" "the brief stays token-free"
assert_eq "{{DERAILLEUR_ROOT}}" "$(grep -o '{{[A-Z_]*}}' "$CMD_FILE" | sort -u | tr -d '\n')" \
  "the command's only token is {{DERAILLEUR_ROOT}}"
assert_eq "" "$(grep -nE '/(Users|home)/' "$CMD_FILE" "$BRIEF_FILE" || true)" \
  "no absolute home paths in the command or brief"
