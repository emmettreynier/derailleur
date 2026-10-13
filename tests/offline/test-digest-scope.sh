#!/usr/bin/env bash
# test-digest-scope.sh (OFFLINE) — board-digest.sh's scope argument (issue #91):
# the opt-in `--here` mode (cwd -> onboarded slug), the reserved `all`, and the
# non-regression of the EMPTY argument that orchestrator-cycle.sh relies on.
#
# Run against fixture board JSON through a recording `gh` shim, in one throwaway ORCH
# sandbox holding two onboarded repos (alpha, beta) whose `working_clone:` is a real
# throwaway git repo, plus a git repo with no manifest (the "hub") and a non-git dir.
#
# What it holds:
#   * `--here` from (a) alpha's working clone, (b) a dispatch worktree of it and (c) a
#     subdirectory of it all resolve to `alpha` — and produce the same digest;
#   * `--here` from (d) a git repo with no manifest and (e) a non-git dir render the
#     WHOLE board with the fallback header line, never an opaque failure;
#   * `all` (with or without `--here`) and an empty argument are byte-identical;
#   * an empty argument is byte-identical — output AND every `gh` call — to a golden
#     recorded from the PRE-#91 board-digest.sh (tests/fixtures/digest-scope/). This
#     is what protects orchestrator-cycle.sh, which calls the digest with no argument.
#     It must not even look at the cwd: a no-arg run from inside alpha's clone is
#     still the whole board.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

command -v python3 >/dev/null 2>&1 \
  || { skip "python3 not installed — skipping board-digest scope"; exit 0; }
command -v git >/dev/null 2>&1 \
  || { skip "git not installed — skipping board-digest scope"; exit 0; }

GOLDEN_DIR="$REPO_ROOT/tests/fixtures/digest-scope"
OWNER="test-operator"            # PR_OWNER in write_filled_conf

# --- one sandbox for every case ------------------------------------------------
SB="$(new_sandbox)"
sandbox_copy_script "$SB" board-digest
cp "$REPO_ROOT/bin/config-common.sh" "$SB/bin/config-common.sh"
write_filled_conf "$SB"

ROOT="$(cd "$(sandbox_tmp)" && pwd -P)"
CLONE="$ROOT/clones/alpha"
WT="$ROOT/worktrees/alpha/issue-1"
HUB="$ROOT/clones/hub"
NOGIT="$ROOT/not-a-repo"
mkdir -p "$CLONE/sub/dir" "$ROOT/clones/beta" "$ROOT/worktrees/alpha" "$HUB" "$NOGIT"

gitq() { git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main "$@"; }
gitq -C "$CLONE" init -q
gitq -C "$CLONE" commit -q --allow-empty -m init
gitq -C "$CLONE" worktree add -q -b issue-1 "$WT"
gitq -C "$HUB" init -q

for s in alpha beta; do
  write_project_manifest "$SB" "$s" "$OWNER/$s"
  printf 'working_clone: %s\n' "$ROOT/clones/$s" >> "$SB/projects/$s.yml"
done

OWNER="$OWNER" python3 - "$SB/board.json" <<'PY'
import json, os, sys
o = os.environ["OWNER"]
items = []
for repo, num in (("alpha", 1), ("beta", 2)):
    items.append({
        "title": f"{repo} issue", "status": "Up Next", "project": "Research",
        "repository": f"https://github.com/{o}/{repo}", "labels": [],
        "content": {"type": "Issue", "number": num, "title": f"{repo} issue",
                    "body": "Lead line.\n\n- [ ] a criterion"},
    })
json.dump({"items": items}, open(sys.argv[1], "w"))
PY

SHIM="$(sandbox_tmp)"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "project item-list") cat "$GH_BOARD" ;;
  "search issues")     echo '[]' ;;
  "pr list")           echo '[]' ;;
  *) echo "gh shim: unexpected call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$SHIM/gh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SHIM/tmux"; chmod +x "$SHIM/tmux"   # hermetic

CALLS="$_SANDBOX_ROOT/gh-calls.log"

# digest_in DIR [ARGS...] — run the digest with cwd DIR; stdout = the digest with its
# one wall-clock line normalized. GIT_CEILING_DIRECTORIES keeps the non-git case from
# discovering whatever repo the sandbox happens to live under.
digest_in() {
  local dir="$1"; shift
  : >"$CALLS"
  ( cd "$dir" && PATH="$SHIM:$PATH" GH_BOARD="$SB/board.json" GH_CALLS="$CALLS" \
      GIT_CEILING_DIRECTORIES="$ROOT" "$SB/bin/board-digest.sh" "$@" ) \
    | sed -E 's/^# Board digest — .*/# Board digest — <now>/'
}

FALLBACK="cwd not onboarded — showing whole board"

# --- the no-argument golden (recorded from the pre-#91 script) -----------------
noarg="$(digest_in "$NOGIT")"
noarg_calls="$(cat "$CALLS")"
if [ "${WRITE_DIGEST_SCOPE_GOLDEN:-}" = 1 ]; then
  # Only ever on a DELIBERATE change to the no-arg digest; never to make this test pass.
  mkdir -p "$GOLDEN_DIR"
  printf '%s\n' "$noarg" >"$GOLDEN_DIR/noarg-digest.golden.md"
  printf '%s\n' "$noarg_calls" >"$GOLDEN_DIR/noarg-gh-calls.golden.txt"
  echo "wrote golden to $GOLDEN_DIR"; exit 0
fi
assert_file_present "$GOLDEN_DIR/noarg-digest.golden.md" "the no-arg digest golden is present"
assert_eq "$(cat "$GOLDEN_DIR/noarg-digest.golden.md")" "$noarg" \
  "no-arg digest is byte-identical to the pre-#91 golden" \
  "orchestrator-cycle.sh calls the digest with no argument; --here/all must not change it."
assert_eq "$(cat "$GOLDEN_DIR/noarg-gh-calls.golden.txt")" "$noarg_calls" \
  "no-arg digest makes exactly the pre-#91 gh calls (count and arguments)"
assert_not_contains "$noarg" "$FALLBACK" "no-arg digest carries no fallback line"

in_clone_noarg="$(digest_in "$CLONE")"
assert_eq "$noarg" "$in_clone_noarg" \
  "no-arg digest from INSIDE an onboarded clone is still the whole board" \
  "The cwd default is opt-in (--here); an empty argument must never read the cwd."

# --- all == empty ----------------------------------------------------------------
assert_eq "$noarg" "$(digest_in "$NOGIT" all)" "\`all\` is byte-identical to no argument"
assert_eq "$noarg_calls" "$(cat "$CALLS")" "…and makes the same gh calls"
assert_eq "$noarg" "$(digest_in "$CLONE" --here all)" \
  "\`--here all\` (what /orchestrate all sends) is the whole board, even from an onboarded clone"
assert_eq "$noarg" "$(digest_in "$CLONE" ALL)" "\`ALL\` is accepted case-insensitively"

# --- (a)(b)(c) --here resolves to the same slug ---------------------------------
here_a="$(digest_in "$CLONE" --here)"
assert_contains "$here_a" "_Scoped to onboarded repos (alpha)" \
  "(a) --here from the working clone scopes to alpha"
assert_contains "$here_a" "alpha#1 — alpha issue" "(a) …and lists alpha's issue"
assert_not_contains "$here_a" "beta#2" "(a) …and not beta's"
assert_contains "$here_a" "resolved from the cwd" "(a) …and says the scope came from the cwd"
assert_not_contains "$here_a" "$FALLBACK" "(a) …with no fallback line"
assert_eq 3 "$(wc -l <"$CALLS" | tr -d ' ')" \
  "(a) a scoped --here run makes 3 gh calls (board + closed search + alpha's pr list)"

assert_eq "$here_a" "$(digest_in "$WT" --here)" \
  "(b) --here from a dispatch worktree resolves to its parent repo's slug" \
  "Resolution goes through git rev-parse --git-common-dir, so a worktree maps to its clone."
assert_eq "$here_a" "$(digest_in "$CLONE/sub/dir" --here)" \
  "(c) --here from a subdirectory of the clone resolves to the same slug"
assert_eq "$(digest_in "$NOGIT" alpha)" "$(digest_in "$CLONE" alpha --here)" \
  "an explicit slug is accepted on either side of --here (and carries no cwd note)"

here_beta="$(digest_in "$CLONE" --here beta)"
assert_contains "$here_beta" "_Scoped to onboarded repos (beta)" \
  "an explicit slug beats --here (\`/orchestrate beta\` from alpha's clone)"
assert_eq "$(digest_in "$NOGIT" beta)" "$here_beta" \
  "\`--here <slug>\` equals plain \`<slug>\`"

# --- (d)(e) not onboarded -> whole board + fallback line -------------------------
strip_fallback() { grep -vF -- "$FALLBACK"; }
here_d="$(digest_in "$HUB" --here)"
assert_contains "$here_d" "$FALLBACK" "(d) --here from a git repo with no manifest names the fallback"
assert_eq "$noarg" "$(strip_fallback <<<"$here_d")" \
  "(d) …and is otherwise exactly the whole-board digest"
here_e="$(digest_in "$NOGIT" --here)"
assert_contains "$here_e" "$FALLBACK" "(e) --here from a non-git directory names the fallback"
assert_contains "$here_e" "not inside a git repository" "(e) …with the reason"
assert_eq "$noarg" "$(strip_fallback <<<"$here_e")" \
  "(e) …and is otherwise exactly the whole-board digest"

# --- unknown slug still fails loud, as before ------------------------------------
set +e
err="$( (cd "$NOGIT" && PATH="$SHIM:$PATH" GH_BOARD="$SB/board.json" GH_CALLS="$CALLS" \
          "$SB/bin/board-digest.sh" --here nosuch) 2>&1 >/dev/null)"; rc=$?
set -e
assert_rc 1 "$rc" "an explicit unknown slug still exits 1, --here or not"
assert_contains "$err" "no onboarded repo 'nosuch'" "…naming the slug"
