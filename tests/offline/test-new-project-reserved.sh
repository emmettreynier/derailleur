#!/usr/bin/env bash
# test-new-project-reserved.sh (OFFLINE) — bin/new-project.sh refuses the reserved slug
# `all` (issue #91) BEFORE any side effect.
#
# `all` means "the whole board" to `/orchestrate` and `board-digest.sh`, so a repo
# onboarded under that name could never be scoped to. new-project.sh has no --dry-run,
# so the test runs it for real in a sandbox against a recording `gh` shim (and a `git`
# shim, so a regression that reaches the clone step cannot touch the network) and
# asserts: nonzero exit, the reserved word named, ZERO gh calls, no manifest written,
# no clone or worktrees directory created.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

SB="$(new_sandbox)"
sandbox_copy_script "$SB" new-project
sandbox_copy_script "$SB" setup-labels
mkdir -p "$SB/templates"
cp "$REPO_ROOT/templates/project.yml" "$SB/templates/project.yml"

SHIM="$(sandbox_tmp)"
CALLS="$_SANDBOX_ROOT/calls.log"
: >"$CALLS"
for tool in gh git; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "%s"\nexit 0\n' "$tool" "$CALLS" >"$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
DEST="$(sandbox_tmp)"

for slug in all ALL; do
  : >"$CALLS"
  set +e
  out="$(PATH="$SHIM:$PATH" "$SB/bin/new-project.sh" "owner/$slug" \
           --clone "$DEST/clone-$slug" --worktrees "$DEST/wt-$slug" 2>&1)"; rc=$?
  set -e
  assert_ne 0 "$rc" "new-project.sh owner/$slug exits nonzero"
  assert_contains "$out" "reserved" "…and the message names the word reserved"
  assert_contains "$out" "'$slug'" "…and names the slug it refused"
  assert_eq 0 "$(wc -l <"$CALLS" | tr -d ' ')" \
    "…having made ZERO gh/git calls" \
    "The refusal must come before setup-labels.sh / gh repo clone — no side effect at all."
  assert_file_absent "$SB/projects/$slug.yml" "…and written no manifest"
  assert_file_absent "$DEST/clone-$slug" "…nor created a clone dir"
  assert_file_absent "$DEST/wt-$slug" "…nor a worktrees dir"
done

# Non-regression: an ordinary slug still gets past the check (it reaches setup-labels,
# i.e. the shimmed gh is called).
: >"$CALLS"
PATH="$SHIM:$PATH" "$SB/bin/new-project.sh" "owner/allspice" \
  --clone "$DEST/clone-ok" --worktrees "$DEST/wt-ok" >/dev/null 2>&1 || true
assert_contains "$(cat "$CALLS")" "gh label" \
  "a slug merely starting with 'all' is NOT refused (reaches the label step)"
