#!/usr/bin/env bash
# test-to-epoch.sh (offline) — watch-dispatch.sh's to_epoch() parses the launchers'
# `date -u +%FT%TZ` stamps to the same epoch seconds on GNU and BSD date alike (issue #102).
#
# to_epoch tries BSD `date -j -f` first and GNU `date -d` second. #92 found that order
# safe by reading the code: GNU date rejects `-j` with nothing on stdout, so the
# fallback never appends to garbage the way the BSD-first `stat -f` did. This pins that
# reading. The host's own date is checked against python's UTC parse, and the OTHER
# platform's date is emulated by a PATH shim, so both orders run on every CI leg.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../lib/assert.sh"
. "$TEST_DIR/../lib/sandbox.sh"

WD_SRC="$REPO_ROOT/bin/watch-dispatch.sh"

# Pull the REAL function out of the script (not a copy), so a rewrite is tested as-is.
fn_src="$(awk '/^to_epoch\(\) *\{/{on=1} on{print} on&&/^\}/{exit}' "$WD_SRC")"
assert_contains "$fn_src" "to_epoch()" "to_epoch() extracted from bin/watch-dispatch.sh" \
  "The function was renamed or reshaped; update the awk extraction in this test."
eval "$fn_src"

TS="2026-10-07T14:12:00Z"
EXPECT="$(python3 -c 'import calendar,time,sys; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$TS")"

# check_platform LABEL — the same battery under whatever `date` is first on PATH.
check_platform() {
  local label="$1" got
  got="$(to_epoch "$TS")"
  assert_eq "$EXPECT" "$got" "to_epoch under $label date parses an ISO8601Z stamp to epoch seconds" \
    "to_epoch must print only the bare epoch (bin/watch-dispatch.sh); a garbage prefix breaks --since and freshness."
  assert_eq "" "$(to_epoch "not-a-time")" "to_epoch under $label date prints nothing for an unparseable stamp" \
    "An unparseable stamp must be empty so watch-dispatch can reject it (exit 2), not compare on garbage."
  assert_eq "1791382320" "$(to_epoch 1791382320)" "to_epoch under $label date passes epoch seconds through" \
    "An all-digit argument is already epoch seconds and must not reach date at all."
}

# ── host platform ────────────────────────────────────────────────────────────
check_platform "the host's"

T="$(sandbox_tmp)"
# ── emulated GNU coreutils date (the DGX, the ubuntu-latest CI leg) ───────────
# `-j` is not an option: a diagnostic on stderr, NOTHING on stdout, exit 1.
GNU="$T/gnu"; mkdir -p "$GNU"
cat >"$GNU/date" <<'SH'
#!/usr/bin/env bash
# SYNTHETIC test shim: mimics GNU coreutils date's -j / -d behavior (issue #102).
[ "$1" = -u ] && shift
case "$1" in
  -j) echo "date: invalid option -- 'j'" >&2
      echo "Try 'date --help' for more information." >&2
      exit 1 ;;
  -d) exec python3 -c 'import calendar,time,sys
try: print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))
except ValueError:
    sys.stderr.write("date: invalid date %r\n" % sys.argv[1]); sys.exit(1)' "$2" ;;
  *) exit 1 ;;
esac
SH
# ── emulated BSD date (macOS): `-j -f` parses, `-d` is not a parse flag ────────
BSD="$T/bsd"; mkdir -p "$BSD"
cat >"$BSD/date" <<'SH'
#!/usr/bin/env bash
# SYNTHETIC test shim: mimics BSD/macOS date's -j -f / -d behavior (issue #102).
[ "$1" = -u ] && shift
case "$1" in
  -j) [ "$2" = -f ] || exit 1
      exec python3 -c 'import calendar,time,sys
try: print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))
except ValueError:
    sys.stderr.write("Failed conversion of %s using the -f format\n" % sys.argv[1]); sys.exit(1)' "$4" ;;
  -d) echo "date: illegal option -- d" >&2; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$GNU/date" "$BSD/date"

PATH="$GNU:$PATH" check_platform "emulated GNU"
PATH="$BSD:$PATH" check_platform "emulated BSD"
