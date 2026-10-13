#!/usr/bin/env bash
# test-hermetic-env.sh (offline) — the offline tier is hermetic against the operator's
# environment (issue #101). bin/config-common.sh and the launchers EXPORT operator/
# dispatch settings, so a suite run inside a dispatched worker/checker inherits them;
# tests/lib/hermetic.sh lists them and bin/test.sh + tests/lib/sandbox.sh unset them.
#
#   1. drift: every name bin/ really exports (`export NAME`, a launcher's
#      `env "NAME=…" claude`), every env var a host hook reads, and every key
#      orchestrator.conf.example documents is in HERMETIC_VARS (or explicitly exempt);
#   2. runner: a probe offline test run by the real bin/test.sh with EVERY var set to a
#      poison value sees none of them — while a probe ONLINE test still sees them all
#      (the online tier deliberately keeps the caller's environment);
#   3. direct run: sourcing sandbox.sh drops every poisoned var (DERAILLEUR_MACHINE_ENV
#      is then re-pointed at the sandbox's nonexistent path, not left at the poison);
#   4. end to end: a representative digest test (test-digest-scope.sh, the #91 golden)
#      and a launcher test (test-machine-env.sh) run directly under the full poison
#      env still pass. The poison is chosen to change their output if it leaked: a
#      non-empty scheduler allow-list, a DIGEST_SLUG scope, a QUARTO_CHROMIUM value, a
#      machine-env file that exports one.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"
. "$TEST_DIR/../lib/hermetic.sh"

# --- 1. drift: the list covers the real exports ------------------------------
# Exempt, with the reason: PATH is the process's own search path (run-cycle.sh
# rebuilds it for launchd; install.sh only prints an `export PATH=` hint); CAL_BLOCK
# is schedule.sh's plist-render scratch, exported to its own envsubst child only.
EXEMPT="PATH CAL_BLOCK"

# The scanner is written to a file first and run from there: bash 3.2 mis-scans the
# quote characters of a heredoc nested inside `$( … )`, so it must not live in one.
SCAN="$(sandbox_tmp)/scan-exports.py"
cat >"$SCAN" <<'PY'
import glob, os, re
root = os.environ["REPO_ROOT"]
names = set()
name = re.compile(r"[A-Z_][A-Z0-9_]*")
for f in glob.glob(os.path.join(root, "bin", "*.sh")) + [os.path.join(root, "bin", "derailleur")]:
    for line in open(f, encoding="utf-8"):
        if line.lstrip().startswith("#"):
            continue
        # every `export A B=c …` statement, wherever it sits on the line
        for m in re.finditer(r"(?:^|[\s;&|(])export\s+([^;&|)#]*)", line):
            for tok in m.group(1).split():
                n = tok.split("=", 1)[0].strip("'\"")
                if not name.fullmatch(n):
                    break
                names.add(n)
        # a launcher's `CMD=( env "NAME=…" … claude` — the vars a dispatched session gets
        if re.search(r"\benv\s+\"[A-Z_]", line):
            names.update(re.findall(r"\"([A-Z_][A-Z0-9_]*)=", line))
# env vars a host hook reads inside a dispatched session
for f in glob.glob(os.path.join(root, "host", "hooks", "*.py")):
    names.update(re.findall(r"os\.environ(?:\.get)?[\[(]\"([A-Z_][A-Z0-9_]*)\"", open(f).read()))
# every key the conf documents, commented-out optional ones included
for line in open(os.path.join(root, "orchestrator.conf.example"), encoding="utf-8"):
    m = re.match(r"^#?\s*([A-Z_][A-Z0-9_]*)=", line)
    if m:
        names.add(m.group(1))
print("\n".join(sorted(names)))
PY
derived="$(REPO_ROOT="$REPO_ROOT" python3 "$SCAN")"

n_derived=0 missing=""
for v in $derived; do
  n_derived=$((n_derived + 1))
  case " $EXEMPT " in *" $v "*) continue ;; esac
  case " $(echo $HERMETIC_VARS) " in *" $v "*) ;; *) missing="$missing $v" ;; esac
done
# Guard against a vacuous pass: the parser must at least find the identity exports,
# the launcher's ORCH_MANIFEST and the cycle's ORCH_PLAN_ONLY.
for must in OPERATOR_NAME SCHEDULED_REPOS_FILE ORCHESTRATOR_MODEL ORCH_MANIFEST ORCH_LOGS_DIR ORCH_PLAN_ONLY SCHEDULE_SLOTS; do
  assert_contains "$derived" "$must" "drift scan finds the real export $must (scanned $n_derived names)" \
    "The export parser in this test stopped seeing bin/'s exports — fix the parser, not the list."
done
assert_eq "" "$missing" "every real export / hook-read / conf key is in HERMETIC_VARS (or exempt)" \
  "Add the name(s) to HERMETIC_VARS in tests/lib/hermetic.sh, or to EXEMPT here with a reason."

# --- the poison environment --------------------------------------------------
POISON_DIR="$(sandbox_tmp)"
printf 'poison-slug\n' >"$POISON_DIR/scheduled-repos"          # non-empty allow-list
printf 'export QUARTO_CHROMIUM=%s\n' "$POISON_DIR/poison-chromium" >"$POISON_DIR/machine-env"
mkdir -p "$POISON_DIR/orch"

poison_value() {  # VAR — the poison value for VAR (a value that changes output if read)
  case "$1" in
    SCHEDULED_REPOS_FILE)   printf '%s' "$POISON_DIR/scheduled-repos" ;;
    DERAILLEUR_MACHINE_ENV) printf '%s' "$POISON_DIR/machine-env" ;;
    QUARTO_CHROMIUM)        printf '%s' "$POISON_DIR/poison-chromium" ;;
    ORCH|ORCH_DIR|ORCH_LOGS_DIR|VERDICT_ARCHIVE) printf '%s' "$POISON_DIR/orch" ;;
    ORCH_MANIFEST)          printf '%s' "$POISON_DIR/orch/poison.yml" ;;
    LEDGER)                 printf '%s' "$POISON_DIR/orch/poison-ledger.md" ;;
    DIGEST_SLUG)            printf 'poison-slug' ;;
    ORCH_PLAN_ONLY|ORCH_DRY|LIVE) printf '1' ;;
    *)                      printf 'poison-%s' "$1" ;;
  esac
}

# run_poisoned CMD… — export every HERMETIC_VARS name at its poison value, then run
# CMD. It exports into the CURRENT shell, so call it only inside `$( … )`.
run_poisoned() {
  local v
  for v in $HERMETIC_VARS; do
    export "$v=$(poison_value "$v")"
  done
  "$@"
}

# --- 2. runner: bin/test.sh strips them for offline, keeps them for online ---
CO="$(sandbox_tmp)/checkout"
mkdir -p "$CO/bin" "$CO/tests/lib" "$CO/tests/offline" "$CO/tests/online"
cp "$REPO_ROOT/bin/test.sh" "$CO/bin/test.sh"
: >"$CO/bin/derailleur"
cp "$REPO_ROOT/tests/lib/hermetic.sh" "$CO/tests/lib/hermetic.sh"
# The probes deliberately do NOT source sandbox.sh — they see exactly what the runner
# hands them. Each prints one PROBE line per var; it emits no PASS/FAIL of its own.
for tier in offline online; do
  sed "s/@TIER@/$tier/" >"$CO/tests/$tier/test-probe.sh" <<'PROBE'
. "$(dirname "$0")/../lib/hermetic.sh"
for v in $HERMETIC_VARS; do
  eval "printf 'PROBE-@TIER@ %s=%s\n' \"\$v\" \"\${$v-<unset>}\""
done
PROBE
done

rc=0
runner_out="$( cd "$POISON_DIR" && run_poisoned bash "$CO/bin/test.sh" 2>&1 )" || rc=$?
assert_rc 0 "$rc" "bin/test.sh runs the probe checkout under the poison env"

leaked="" kept_missing="" n=0
for v in $HERMETIC_VARS; do
  n=$((n + 1))
  grep -qxF "PROBE-offline $v=<unset>" <<<"$runner_out" || leaked="$leaked $v"
  # ORCH is the one exception: bin/test.sh assigns its own ORCH (its repo root), which
  # overwrites an inherited exported value for both tiers — true before #101 too.
  [ "$v" = ORCH ] && continue
  grep -qxF "PROBE-online $v=$(poison_value "$v")" <<<"$runner_out" || kept_missing="$kept_missing $v"
done
assert_eq "" "$leaked" "bin/test.sh: none of the $n poisoned vars reaches an offline test" \
  "bin/test.sh must call hermetic_unset (tests/lib/hermetic.sh) before each offline file."
assert_eq "" "$kept_missing" "bin/test.sh: the online tier still sees the poisoned vars unchanged (all but ORCH)" \
  "The online tier reads the real conf on purpose — only the offline tier is stripped."

# --- 3. direct run: sourcing sandbox.sh drops them ---------------------------
direct_out="$(
  run_poisoned bash -c '
    . "$1/tests/lib/assert.sh"; . "$1/tests/lib/sandbox.sh"
    for v in $HERMETIC_VARS; do eval "printf \"PROBE %s=%s\\n\" \"\$v\" \"\${$v-<unset>}\""; done
  ' _ "$REPO_ROOT" 2>&1
)"
leaked=""
for v in $HERMETIC_VARS; do
  if [ "$v" = DERAILLEUR_MACHINE_ENV ]; then
    grep -qE "^PROBE DERAILLEUR_MACHINE_ENV=.*/no-machine-env$" <<<"$direct_out" || leaked="$leaked $v"
  else
    grep -qxF "PROBE $v=<unset>" <<<"$direct_out" || leaked="$leaked $v"
  fi
done
assert_eq "" "$leaked" "sandbox.sh: a test run directly sees none of the poisoned vars" \
  "tests/lib/sandbox.sh must source hermetic.sh and call hermetic_unset at source time."

# --- 4. end to end: representative digest + launcher tests stay green --------
for t in test-digest-scope.sh test-machine-env.sh; do
  rc=0
  out="$( run_poisoned bash "$REPO_ROOT/tests/offline/$t" 2>&1 )" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Re-prefix the nested output so bin/test.sh does not tally its PASS/FAIL lines.
    sed 's/^/  | /' <<<"$out" | tail -15 >&2
  fi
  assert_rc 0 "$rc" "$t passes run directly under the full poison env" \
    "A poisoned host var leaked into the sandbox — see the nested output above."
done
