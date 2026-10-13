#!/usr/bin/env bash
# test-detach-fds.sh (offline) — a DETACHED `launch-worker` / `launch-checker` returns as
# soon as the dispatch has started, even when its output is piped or captured (issue #100).
#
# Why: run_in_new_session (bin/dispatch-common.sh) redirected each INNER step of the
# detached chain to $LOG, but the session leader itself — the backgrounded subshell that
# execs the python setsid shim, then `bash -c` — kept the launcher's inherited
# stdin/stdout/stderr for its whole life. A reader waiting for EOF on the launcher's
# stdout (`dr launch-worker … | tail`, `$(…)`, a tool harness) therefore waited for the
# WORKER to exit: three parallel launches from /orchestrate each hit the 120 s Bash
# timeout. With output redirected to a file every launch returned in about a second.
#
# Everything here runs against a throwaway sandbox: a local bare `origin`, a stub
# `claude` that only sleeps then prints a result line (SYNTHETIC — no real agent runs),
# and a stub `gh`. The detached chains are killed on exit.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

STUB_SLEEP=20      # how long the stub claude runs; a leaking launch blocks this long
RETURN_LIMIT=8     # a clean detached launch returns well inside this (seconds)

SB="$(new_sandbox)"
write_filled_conf "$SB"
for s in launch-worker launch-checker dispatch-common config-common; do sandbox_copy_script "$SB" "$s"; done
cp -R "$REPO_ROOT/host" "$SB/host"
cp -R "$REPO_ROOT/templates" "$SB/templates"
cp "$REPO_ROOT/briefs/worker-brief.md" "$REPO_ROOT/briefs/checker-brief.md" "$SB/briefs/"
chmod +x "$SB/bin/launch-worker.sh" "$SB/bin/launch-checker.sh"

# --- a real git origin + working clone, so the worktree step runs for real -----------
ORIGIN="$(sandbox_tmp)/origin.git"
CLONE="$(sandbox_tmp)/clone"
WTS="$(sandbox_tmp)"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
git -C "$CLONE" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$CLONE" branch -M main
git -C "$CLONE" push -q origin main
git -C "$CLONE" push -q origin main:issue-7         # the checker's PR head branch
git -C "$CLONE" remote set-head origin main >/dev/null 2>&1 || true

# Code-only manifest (raw_resolved == working_clone): no data/ scaffold, gate exempt.
cat >"$SB/projects/detach-demo.yml" <<YML
repo: test-operator/detach-demo
working_clone: $CLONE
worktrees_dir: $WTS
data_root: $CLONE
raw_resolved: $CLONE
YML

# --- stubs: claude sleeps then prints a result line; gh answers `pr view` only --------
STUBS="$(sandbox_tmp)"
cat >"$STUBS/claude" <<SH
#!/usr/bin/env bash
# SYNTHETIC stand-in for claude: hold the session open, then emit a result line.
sleep "\${STUB_CLAUDE_SLEEP:-$STUB_SLEEP}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"stub","total_cost_usd":0}'
SH
cat >"$STUBS/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s' '{"isDraft":false,"headRefName":"issue-7","closingIssuesReferences":[{"number":7}],"state":"OPEN"}' ;;
esac
exit 0
SH
chmod +x "$STUBS/claude" "$STUBS/gh"
export PATH="$STUBS:$PATH"

# Every detached chain we start is recorded here and killed on exit, so a failing run
# never leaves stub sleeps behind (the sandbox trap is chained after it).
PIDS_FILE="$(sandbox_tmp)/pids"; : >"$PIDS_FILE"
_kill_chains() {
  local p
  while read -r p; do
    [ -n "$p" ] || continue
    # `|| true`: most chains have already finished, and a failing bare `kill` under
    # `set -e` would abort this EXIT trap and turn a green run into exit 1.
    kill -TERM -- "-$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done <"$PIDS_FILE"
  _sandbox_cleanup
  return 0
}
trap _kill_chains EXIT

now() { python3 -c 'import time; print(int(time.time()))'; }
pid_of() { printf '%s\n' "$1" | sed -nE 's/^  pid ([0-9]+) .*/\1/p' | head -1; }

# launch ROLE N — echo the launcher's command for ROLE (worker issue / checker PR N).
launcher() { printf '%s' "$SB/bin/launch-$1.sh"; }

# --- 1. piped into cat, and captured via $(…): returns fast, prints the pid line ------
for role in worker checker; do
  n=7; [ "$role" = checker ] && n=3
  for mode in pipe capture; do
    # A fresh worktree each time is not needed: both launchers reuse it idempotently.
    t0="$(now)"
    if [ "$mode" = pipe ]; then
      out="$("$(launcher "$role")" detach-demo "$n" 2>&1 | cat)"
    else
      out="$("$(launcher "$role")" detach-demo "$n" 2>&1)"
    fi
    dt=$(( $(now) - t0 ))
    pid="$(pid_of "$out")"
    [ -n "$pid" ] && echo "$pid" >>"$PIDS_FILE"
    assert_contains "$out" "  pid " "launch-$role ($mode) prints the pid line" \
      "The detached branch of bin/launch-$role.sh must still print '  pid N (detached, own session…'."
    if [ "$dt" -le "$RETURN_LIMIT" ]; then
      pass "launch-$role ($mode) returns in ${dt}s while the stub claude sleeps ${STUB_SLEEP}s"
    else
      fail "launch-$role ($mode) took ${dt}s to return (stub claude sleeps ${STUB_SLEEP}s)" \
        "The detached chain still holds the caller's stdout/stderr open — run_in_new_session in bin/dispatch-common.sh must point the session leader's fds at \$LOG and /dev/null (issue #100)."
    fi
  done
done

# --- 2. the synchronous stdout is unchanged: Dispatching / pid / watch, in order -------
# The launcher resolves ORCH with `cd … && pwd`, which drops the `//` a trailing-slash
# $TMPDIR leaves in $SB; the worktree path comes from the manifest verbatim.
ORCH_PATH="$(cd "$SB" && pwd)"
out="$("$(launcher worker)" detach-demo 7 | cat)"
pid="$(pid_of "$out")"; echo "$pid" >>"$PIDS_FILE"
expected="Dispatching worker for test-operator/detach-demo #7 → $WTS/issue-7 (log: $ORCH_PATH/logs/detach-demo-issue-7.log)
  pid $pid (detached, own session)
  watch: dr watch-dispatch detach-demo#7@$pid"
assert_eq "$expected" "$out" "launch-worker's synchronous stdout is the same three lines" \
  "Issue #100 must not change what the launcher prints (Dispatching / pid / watch)."
out="$("$(launcher checker)" detach-demo 3 | cat)"
cpid="$(pid_of "$out")"; echo "$cpid" >>"$PIDS_FILE"
expected="Dispatching checker for test-operator/detach-demo PR #3 (closes #7) → $WTS/issue-7 (log: $ORCH_PATH/logs/detach-demo-pr-3.log)
  pid $cpid  (detached, own session; mutation + completion checks in the log)
  watch: dr watch-dispatch detach-demo#pr3@$cpid"
assert_eq "$expected" "$out" "launch-checker's synchronous stdout is the same three lines"

# --- 3. the printed pid is the session leader, and holds none of the caller's fds -----
# os.getsid/getpgid, not `ps -o sid=`: BSD ps has no sid keyword (macOS prints its
# whole keyword list instead).
ids="$(python3 -c 'import os, sys; p = int(sys.argv[1]); print(os.getsid(p), os.getpgid(p))' "$pid")"
assert_eq "$pid $pid" "$ids" "the printed worker pid is its session's leader and leads its process group" \
  "run_in_new_session must keep the os.setsid() shim and exec-preserved pid."
if command -v lsof >/dev/null 2>&1; then
  # fds 0-2 alone are not enough: before #100 they read /dev/null + $LOG mid-step, while
  # bash had parked the caller's pipe on fds 10/11 (the saved originals of the builtin
  # `eval … >>log` redirect). So every open fd is inspected, by type.
  fds="$(lsof -a -p "$pid" -d 0,1,2 -Fn 2>/dev/null | sed -n 's/^n//p' | tr '\n' ' ')"
  assert_contains "$fds" "/dev/null" "the session leader's stdin is /dev/null" \
    "run_in_new_session must give the detached chain stdin </dev/null."
  assert_contains "$fds" "detach-demo-issue-7.log" "the session leader's stdout/stderr are the dispatch log" \
    "run_in_new_session must point the detached chain's stdout/stderr at \$LOG."
  types="$(lsof -a -p "$pid" -Ft 2>/dev/null | sed -n 's/^t//p' | sort -u | tr '\n' ' ')"
  case "$types" in
    *PIPE*|*FIFO*) fail "the session leader still holds a pipe (fd types: $types)" \
                     "The caller's stdout leaked into the detached chain (issue #100): run_in_new_session must redirect the exec itself." ;;
    *) pass "the session leader holds no pipe on any fd (types: $types)" ;;
  esac
else
  skip "lsof not on PATH — fd ownership not inspected"
fi

# --- 4. survives the caller's process-group teardown; finalize still writes the ledger -
# The caller is its own process group (python setpgid, then exec bash) that launches a
# short worker and then lingers; we SIGTERM that whole group, as an orchestrator
# session's teardown would, and the worker must keep running and finalize afterwards.
for f in "$SB"/ledger.md; do : >"$f"; done
CALLER_OUT="$(sandbox_tmp)/caller.out"
STUB_CLAUDE_SLEEP=3 python3 -c 'import os, sys
os.setpgid(0, 0)
os.execvp(sys.argv[1], sys.argv[1:])' \
  bash -c '"$1" detach-demo 7 >"$2" 2>&1; sleep 60' _ "$(launcher worker)" "$CALLER_OUT" &
CALLER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '  pid ' "$CALLER_OUT" 2>/dev/null && break; sleep 1; done
wpid="$(pid_of "$(cat "$CALLER_OUT")")"
[ -n "$wpid" ] && echo "$wpid" >>"$PIDS_FILE"
kill -TERM -- "-$CALLER" 2>/dev/null || true
wait "$CALLER" 2>/dev/null || true
if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
  pass "the worker survives SIGTERM to the caller's process group"
else
  fail "the worker (pid ${wpid:-?}) died with the caller's process group" \
    "run_in_new_session must keep os.setsid() isolation."
fi
for _ in $(seq 1 15); do
  grep -q "pid $wpid .*status dispatched" "$SB/ledger.md" || break
  sleep 1
done
line="$(grep "pid $wpid " "$SB/ledger.md" | tail -1)"
assert_matches "$line" 'status [a-z]' "finalize_dispatch wrote a ledger line for the worker" \
  "finalize_dispatch must still run inside the detached session."
case "$line" in
  *"status dispatched"*) fail "finalize_dispatch never flipped the ledger status: $line" \
                           "The trailing finalize step of the detached chain did not run." ;;
  *) pass "finalize_dispatch flipped the ledger status off 'dispatched' ($(printf '%s' "$line" | sed -E 's/.*status //'))" ;;
esac
log="$SB/logs/detach-demo-issue-7.log"
assert_contains "$(cat "$log")" '"result":"stub"' "the command's own output still lands in \$LOG" \
  "Nothing the chain wrote to \$LOG before issue #100 may be lost."

# --- 5. --foreground is unchanged: claude's output is still teed to the terminal -------
out="$(STUB_CLAUDE_SLEEP=0 "$(launcher worker)" detach-demo 7 --foreground 2>&1)"
assert_contains "$out" '"result":"stub"' "launch-worker --foreground still tees the agent's output to the terminal" \
  "The supervised branch must keep \`… 2>&1 | tee \"\$LOG\"\` — issue #100 only touches the detached chain."
out="$(STUB_CLAUDE_SLEEP=0 "$(launcher checker)" detach-demo 3 --foreground 2>&1)"
assert_contains "$out" '"result":"stub"' "launch-checker --foreground still tees the agent's output to the terminal"
