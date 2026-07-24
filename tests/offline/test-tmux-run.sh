#!/usr/bin/env bash
# test-tmux-run.sh (offline) — tmux-run.sh name/log derivation, --tail validation,
# {{SLUG}} token wiring, and the atomic-create mutex. Migrated from smoke-test.sh
# check (f). The dry-run + static-wiring halves are deterministic and offline; the
# live mutex half needs tmux and SKIPs cleanly when it's absent. No network, nothing
# spent.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

assert_file_present "$REPO_ROOT/bin/tmux-run.sh" "bin/tmux-run.sh present" \
  "The detached-job wrapper is missing from bin/."

SB="$(new_sandbox)"
sandbox_copy_script "$SB" tmux-run
TMUXRUN="$SB/bin/tmux-run.sh"
TR_DATA="$SB/data"
TR_NAME="derail-owner-demo-repo-7"   # derived from repo owner/demo-repo + issue 7
write_project_manifest "$SB" zz-smoke owner/demo-repo "$TR_DATA"

# dry-run: derives name + <data_root>/logs path, creates nothing.
rc=0; dr_out="$("$TMUXRUN" zz-smoke 7 --dry-run 2>&1)" || rc=$?
assert_rc 0 "$rc" "tmux-run --dry-run exits 0" \
  "The wrapper should derive the name/log and exit 0 in --dry-run; see bin/tmux-run.sh."
assert_contains "$dr_out" "$TR_NAME" "tmux-run --dry-run derives the canonical name" \
  "Name derivation (repo with /->-, + issue) is broken in bin/tmux-run.sh."
assert_contains "$dr_out" "$TR_DATA/logs/$TR_NAME.log" "tmux-run --dry-run computes the durable log path" \
  "Log-path derivation is broken in bin/tmux-run.sh."
assert_file_absent "$TR_DATA/logs" "tmux-run --dry-run creates nothing" \
  "The --dry-run branch must precede any mkdir in bin/tmux-run.sh."

# --tail flag: integer accepted, non-integer rejected (both dry-run only).
rc=0; "$TMUXRUN" zz-smoke 7 --tail 5 --dry-run >/dev/null 2>&1 || rc=$?
assert_rc 0 "$rc" "tmux-run --tail 5 accepts an integer" \
  "The --tail N flag must be parsed before '--'; see the arg loop in bin/tmux-run.sh."
rc=0; "$TMUXRUN" zz-smoke 7 --tail bogus --dry-run >/dev/null 2>&1 || rc=$?
assert_ne 0 "$rc" "tmux-run --tail bogus is rejected" \
  "The --tail validation (case '*[!0-9]*') is missing/broken in bin/tmux-run.sh."

# {{SLUG}} token wiring: brief invokes it, launcher supplies it — a both-ends static
# check so the token can't be present in one file and unwired in the other.
if grep -qF 'dr tmux-run {{SLUG}}' "$REPO_ROOT/briefs/worker-brief.md"; then
  pass "worker-brief.md invokes 'dr tmux-run {{SLUG}}'"
else
  fail "worker-brief.md does not invoke 'dr tmux-run {{SLUG}}'" \
    "The brief should render the slug token, not describe '<repo-slug>' — see briefs/worker-brief.md."
fi
if grep -q 'BRIEF_SLUG=' "$REPO_ROOT/bin/launch-worker.sh"; then
  pass "launch-worker.sh sets BRIEF_SLUG for the render"
else
  fail "launch-worker.sh does not set BRIEF_SLUG" \
    "Add BRIEF_SLUG=\"\$REPO_SLUG\" to the render_brief invocation in bin/launch-worker.sh."
fi

# live mutex walk — needs tmux; SKIP cleanly (never fail) when unavailable.
if ! command -v tmux >/dev/null 2>&1; then
  skip "tmux not installed — skipping tmux-run live mutex case"
else
  tmux kill-session -t "$TR_NAME" 2>/dev/null || true   # clean slate
  # first call → created (command echoes immediately so the tee'd log is non-empty at once)
  rc=0; a_out="$("$TMUXRUN" zz-smoke 7 -- sh -c 'echo started; sleep 60' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$a_out" | grep -q 'status=created'; then
    tmux kill-session -t "$TR_NAME" 2>/dev/null || true
    fail "tmux-run first call did not report status=created (exit $rc)" \
         "Atomic create path is broken in bin/tmux-run.sh."
  fi
  # second identical call → exists-alive + log tail; must NOT spawn a duplicate
  rc=0; b_out="$("$TMUXRUN" zz-smoke 7 -- sh -c 'echo started; sleep 60' 2>&1)" || rc=$?
  dup="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cx "$TR_NAME" || true)"
  logsz=0; [ -s "$TR_DATA/logs/$TR_NAME.log" ] && logsz=1
  tmux kill-session -t "$TR_NAME" 2>/dev/null || true   # teardown before asserting so nothing leaks
  assert_matches "$b_out" 'status=exists-alive' "tmux-run second call reports status=exists-alive" \
    "The mutex/reconcile classification is broken in bin/tmux-run.sh."
  assert_eq 1 "$dup" "exactly one session exists (atomic-create mutex, no duplicate)" \
    "A colliding create must report the existing session, never create a second."
  assert_eq 1 "$logsz" "durable log written (non-empty) at <data_root>/logs" \
    "The tee'd log path (2>&1 | tee <log>) is broken in bin/tmux-run.sh."
fi
