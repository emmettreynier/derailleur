#!/usr/bin/env bash
# tests/lib/sandbox.sh — throwaway-ORCH sandbox helpers. SOURCED after assert.sh.
#
# WHY: every test that exercises a bin/ script must do so against a fake repo root
# so the script's `cd "$(dirname …)/.." ` resolution lands in a scratch dir — never
# the real checkout, never a real orchestrator.conf, never real project data. All
# sandboxes live under ONE mktemp root removed on exit (single trap, no space-in-path
# hazard from a dir list), matching the old smoke-test's TMPROOT discipline.
#
# Depends on REPO_ROOT (exported by assert.sh) to copy real scripts/briefs in.

# The single scratch root + its cleanup trap are established at SOURCE time, in the
# test's MAIN shell. They must NOT be created lazily inside new_sandbox/sandbox_tmp:
# those run in a `$(…)` command-substitution subshell, so a trap set there would fire
# when that subshell exits and delete the root out from under the caller.
_SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/derailleur-test.XXXXXX")"

# Cleanup is bare-short-circuit safe (explicit `return 0`, per CLAUDE.md) so it can't
# abort a `set -e` test if it happens to be the last statement before exit.
_sandbox_cleanup() {
  [ -n "$_SANDBOX_ROOT" ] && rm -rf "$_SANDBOX_ROOT"
  return 0
}
trap _sandbox_cleanup EXIT

# new_sandbox — echo a fresh sandbox ORCH dir pre-scaffolded with the runtime layout
# (bin/ logs/ projects/ state/ briefs/). Callers copy in only the scripts they need.
new_sandbox() {
  local d
  d="$(mktemp -d "$_SANDBOX_ROOT/orch.XXXXXX")"
  mkdir -p "$d/bin" "$d/logs" "$d/projects" "$d/state" "$d/briefs"
  printf '%s' "$d"
}

# sandbox_tmp — echo a fresh throwaway subdir under the sandbox root (for symlinks,
# fixtures, gh shims, etc. that aren't a full ORCH).
sandbox_tmp() {
  mktemp -d "$_SANDBOX_ROOT/tmp.XXXXXX"
}

# sandbox_copy_script SANDBOX NAME — copy $REPO_ROOT/bin/NAME.sh into the sandbox's
# bin/ so it resolves the sandbox as its repo root when run. Fails loud if absent.
sandbox_copy_script() {
  local sb="$1" name="$2"
  [ -f "$REPO_ROOT/bin/$name.sh" ] \
    || fail "sandbox_copy_script: no $REPO_ROOT/bin/$name.sh to copy" \
            "The script under test is missing from bin/."
  cp "$REPO_ROOT/bin/$name.sh" "$sb/bin/$name.sh"
}

# write_filled_conf DIR — write a fully-populated throwaway orchestrator.conf.
write_filled_conf() {
  cat >"$1/orchestrator.conf" <<'CONF'
OPERATOR_NAME="Test Operator"
GITHUB_HANDLE="test-operator"
PR_OWNER="test-operator"
LAUNCHD_LABEL="com.test-operator.orchestrator"
BOARD_PROJECT="1"
CONF
}

# write_blank_conf DIR FIELD — write a conf with exactly FIELD left blank.
write_blank_conf() {
  local dir="$1" blank="$2" v
  {
    for v in OPERATOR_NAME GITHUB_HANDLE PR_OWNER LAUNCHD_LABEL BOARD_PROJECT; do
      if [ "$v" = "$blank" ]; then
        printf '%s=""\n' "$v"
      else
        printf '%s="filled-%s"\n' "$v" "$v"
      fi
    done
  } >"$dir/orchestrator.conf"
}

# write_project_manifest DIR SLUG REPO [DATA_ROOT] — scaffold a minimal
# projects/<slug>.yml so onboarding-gated logic (enable/disable, worktree iter) sees it.
write_project_manifest() {
  local dir="$1" slug="$2" repo="$3" data_root
  data_root="${4:-$dir/data}"
  cat >"$dir/projects/$slug.yml" <<YML
repo: $repo
data_root: $data_root
YML
}

# fake_gh_on_path DIR [BODY] — drop a no-op `gh` shim (exit 0, empty stdout by
# default) into DIR and echo a PATH prefix string. Used to isolate the LOCAL path of
# a script that shells out to gh, keeping an offline test hermetic + fast.
fake_gh_on_path() {
  local dir="$1"
  cat >"$dir/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/gh"
  printf '%s' "$dir"
}
