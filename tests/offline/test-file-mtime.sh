#!/usr/bin/env bash
# test-file-mtime.sh (offline) — watch-dispatch.sh's file_mtime() returns a bare
# integer epoch mtime on GNU and BSD stat alike (issue #92).
#
# The defect this covers: file_mtime tried BSD `stat -f '%m'` first. On GNU coreutils
# `-f` is --file-system and '%m' a second FILE operand, so stat printed the fs block
# for the real file, failed on '%m', and the `||` fallback APPENDED the mtime to that
# garbage. `[ "$m" -ge "$de" ]` then errored every poll and a fresh checker verdict
# was never read, so the terminal line never named it.
#
# The host's own stat is checked against `date -r`; the OTHER platform's stat is
# emulated by a PATH shim, so both orders are exercised on every runner (CI is macOS).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

WD_SRC="$REPO_ROOT/bin/watch-dispatch.sh"

# Pull the REAL function out of the script (not a copy), so a rewrite is tested as-is.
fn_src="$(awk '/^file_mtime\(\) *\{/{on=1} on{print} on&&/^\}/{exit}' "$WD_SRC")"
assert_contains "$fn_src" "file_mtime()" "file_mtime() extracted from bin/watch-dispatch.sh" \
  "The function was renamed or reshaped; update the awk extraction in this test."
eval "$fn_src"

T="$(sandbox_tmp)"
F="$T/verdict.json"
printf '{"verdict":"pass"}\n' >"$F"
touch -t 202610071412 "$F"
EXPECT="$(date -r "$F" +%s)"

# ── host platform ────────────────────────────────────────────────────────────
got="$(file_mtime "$F")"
assert_eq "$EXPECT" "$got" "file_mtime on the host's stat equals \`date -r <file> +%s\`" \
  "file_mtime must print only the epoch-seconds mtime (bin/watch-dispatch.sh, issue #92)."
assert_eq "0" "$(file_mtime "$T/missing.json")" "file_mtime of a missing file is 0" \
  "An unreadable path must yield 0 so the freshness test treats it as stale."

# ── emulated GNU coreutils stat (the DGX) ────────────────────────────────────
# `-f` = --file-system: fs block for the real file on stdout, then fail on '%m'.
GNU="$T/gnu"; mkdir -p "$GNU"
cat >"$GNU/stat" <<'SH'
#!/usr/bin/env bash
# SYNTHETIC test shim: mimics GNU coreutils stat's -c / -f behavior (issue #92).
case "$1" in
  -c) [ "$2" = '%Y' ] && [ -e "$3" ] || exit 1; date -r "$3" +%s ;;
  -f) printf '  File: "%s"\n    ID: 4178f3654b8d9a6f Namelen: 255     Type: ext2/ext3\n' "$3"
      echo "stat: cannot read file system information for '$2': No such file or directory" >&2
      exit 1 ;;
  *) exit 1 ;;
esac
SH
# ── emulated BSD stat (macOS): rejects -c outright ──────────────────────────
BSD="$T/bsd"; mkdir -p "$BSD"
cat >"$BSD/stat" <<'SH'
#!/usr/bin/env bash
# SYNTHETIC test shim: mimics BSD/macOS stat's -c / -f behavior (issue #92).
case "$1" in
  -c) echo "stat: illegal option -- c" >&2; exit 1 ;;
  -f) [ "$2" = '%m' ] && [ -e "$3" ] || exit 1; date -r "$3" +%s ;;
  *) exit 1 ;;
esac
SH
chmod +x "$GNU/stat" "$BSD/stat"

got="$(PATH="$GNU:$PATH" file_mtime "$F")"
assert_eq "$EXPECT" "$got" "file_mtime under GNU stat returns the bare integer mtime" \
  "On GNU, stat -f prints an fs block and exits 1; file_mtime must not let that through."
got="$(PATH="$BSD:$PATH" file_mtime "$F")"
assert_eq "$EXPECT" "$got" "file_mtime under BSD stat returns the bare integer mtime" \
  "On BSD, stat -c is rejected; file_mtime must fall back to stat -f '%m'."
assert_eq "0" "$(PATH="$GNU:$PATH" file_mtime "$T/missing.json")" \
  "file_mtime of a missing file is 0 under GNU stat" \
  "A missing verdict file must read as 0, never as stat's diagnostic output."

# ── end to end: a finalized checker's fresh verdict is named under GNU stat ─────
SB="$(new_sandbox)"
sandbox_copy_script "$SB" watch-dispatch
cat >"$SB/ledger.md" <<LEDGER
- check pr#21 | owner/demo | issue-10 | $SB/logs/demo-pr-21.log | pid 1 | dispatched 2026-01-01T00:00:00Z | status done
LEDGER
printf '{"verdict":"changes_requested"}\n' >"$SB/logs/demo-pr-21-verdict.json"
rc=0; out="$(PATH="$GNU:$PATH" "$SB/bin/watch-dispatch.sh" --dry-run demo#pr21 2>&1)" || rc=$?
assert_rc 0 "$rc" "watch-dispatch under GNU stat exits 0"
assert_matches "$out" 'demo#pr21 \(checker\) -> changes_requested' \
  "under GNU stat a fresh verdict is named on the terminal line" \
  "file_mtime garbage leaves vfresh=0, so the line falls back to bare '-> done' (issue #92)."
assert_not_contains "$out" "integer expression expected" \
  "under GNU stat the freshness comparison raises no integer-expression error" \
  "file_mtime must return a bare integer; see bin/watch-dispatch.sh."

# ── no other BSD-first stat call left in bin/ or host/ ───────────────────────
# Non-comment lines only; the one allowed hit is file_mtime's digit-checked fallback.
n="$(grep -rnE '^[^#]*stat -f' "$REPO_ROOT/bin" "$REPO_ROOT/host" \
      | grep -vc "^$REPO_ROOT/bin/watch-dispatch.sh:[0-9]*:  for m in " || true)"
assert_eq "0" "$n" "no stat -f call outside file_mtime's guarded fallback in bin/ or host/" \
  "A new BSD-first stat call is unsafe on GNU (issue #92) — route it through a guarded helper."

