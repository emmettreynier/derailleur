#!/usr/bin/env python3
"""manifest-parsers.py — run the deny-hook's manifest list parser and the launchers'
`yml_list()` side by side, against the same manifest, and compare them (issue #76).

WHY A HELPER AND NOT A REIMPLEMENTATION: the point of the conformance test is to catch
the two REAL parsers drifting apart, so neither is copied here. The hook's `list_items()`
is reached by importing `host/hooks/raw-data-guard.py` and calling its
`_manifest_reader()`; the launcher's is reached by EXTRACTING the python program out of
the `yml_list() { python3 - … <<'PY' … PY }` heredoc in `bin/launch-*.sh` and exec'ing
that exact source with the argv bash would pass it. A restructure that defeats either
route fails loudly rather than silently comparing nothing.

Usage:
  manifest-parsers.py extract       <launcher.sh>
  manifest-parsers.py hook-list     <hook.py>     <manifest> <key>
  manifest-parsers.py launcher-list <launcher.sh> <manifest> <key>
  manifest-parsers.py compare       <launcher.sh> <hook.py>  <manifest>

`compare` walks EVERY top-level key in the manifest and prints, on success:
    SAME keys=<n>
and on divergence one `DIFF <key> hook=<list> launcher=<list>` line per key, then
`DIVERGED <n>`, exiting 1. Any structural failure (no heredoc found, hook unimportable)
exits 2 with an `ERROR` line — never a silent pass.
"""
import importlib.util
import io
import os
import re
import sys


def die(msg):
    print("ERROR %s" % msg)
    sys.exit(2)


def extract_launcher_src(launcher):
    """The python program inside the launcher's `yml_list()` heredoc, verbatim."""
    try:
        text = open(launcher, encoding="utf-8").read()
    except OSError as e:
        die("cannot read launcher %s: %s" % (launcher, e))
    # `[^\n]*` on the opening line, never `.*`: under DOTALL a greedy `.*` runs past
    # this heredoc to the LAST `<<'PY'` in the file and extracts the wrong program.
    m = re.search(r"^yml_list\(\) \{ python3 - [^\n]*<<'PY'\n(.*?)^PY\n", text,
                  re.MULTILINE | re.DOTALL)
    if not m:
        die("no `yml_list() { python3 - … <<'PY'` heredoc in %s — the launcher parser "
            "was restructured; update tests/lib/manifest-parsers.py to match" % launcher)
    return m.group(1)


def launcher_list(launcher, manifest, key):
    """Run the extracted launcher source the way bash does: argv = (manifest, key, sep),
    newline separator, output split back into a list."""
    src = extract_launcher_src(launcher)
    buf, old_argv, old_out = io.StringIO(), sys.argv, sys.stdout
    sys.argv = ["yml_list", manifest, key, "\n"]
    sys.stdout = buf
    try:
        exec(compile(src, "<%s:yml_list>" % os.path.basename(launcher), "exec"),
             {"__name__": "__main__"})
    finally:
        sys.argv, sys.stdout = old_argv, old_out
    return [ln for ln in buf.getvalue().split("\n") if ln != ""]


def hook_reader(hookpy, manifest):
    spec = importlib.util.spec_from_file_location("raw_data_guard", hookpy)
    if spec is None or spec.loader is None:
        die("cannot load hook %s" % hookpy)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    os.environ["ORCH_MANIFEST"] = manifest
    r = mod._manifest_reader()
    if r is None:
        die("hook _manifest_reader() returned None for %s (unreadable manifest?)" % manifest)
    return r


def hook_list(hookpy, manifest, key):
    _data_root, _scalar, list_items = hook_reader(hookpy, manifest)
    return list_items(key)


def top_level_keys(manifest):
    try:
        text = open(manifest, encoding="utf-8").read()
    except OSError as e:
        die("cannot read manifest %s: %s" % (manifest, e))
    keys, seen = [], set()
    for k in re.findall(r"^([A-Za-z_][A-Za-z0-9_]*):", text, re.MULTILINE):
        if k not in seen:
            seen.add(k)
            keys.append(k)
    return keys


def main():
    if len(sys.argv) < 2:
        die("no mode given")
    mode = sys.argv[1]
    if mode == "extract":
        sys.stdout.write(extract_launcher_src(sys.argv[2]))
    elif mode == "hook-list":
        for it in hook_list(sys.argv[2], sys.argv[3], sys.argv[4]):
            print(it)
    elif mode == "launcher-list":
        for it in launcher_list(sys.argv[2], sys.argv[3], sys.argv[4]):
            print(it)
    elif mode == "compare":
        launcher, hookpy, manifest = sys.argv[2], sys.argv[3], sys.argv[4]
        keys = top_level_keys(manifest)
        if not keys:
            die("no top-level keys found in %s — nothing was compared" % manifest)
        bad = 0
        for k in keys:
            h, l = hook_list(hookpy, manifest, k), launcher_list(launcher, manifest, k)
            if h != l:
                bad += 1
                print("DIFF %s hook=%r launcher=%r" % (k, h, l))
        if bad:
            print("DIVERGED %d" % bad)
            sys.exit(1)
        print("SAME keys=%d" % len(keys))
    else:
        die("unknown mode %r" % mode)


if __name__ == "__main__":
    main()
