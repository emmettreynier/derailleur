#!/usr/bin/env python3
"""PreToolUse guard for orchestrator workers — Safety Layer 2 (see design.md).

Workers run with `--permission-mode bypassPermissions` (no human to approve), so this
hook is the deterministic, harness-enforced backstop that DENIES dangerous tool calls
before they run. It blocks two categories:

  1. Universal dangers (no manifest needed):
       - `rm -rf` / recursive-and-force deletes
       - `git push` to main/master, force-pushes, `+refspec` overwrites
  2. Writes/deletes into a project's READ-ONLY raw data, per the per-project manifest's
     `raw_paths` (resolved against `data_root`, plus the canonical `raw_resolved` target).

Backed by Layer 1 (read-only data / `--add-dir` scoping) and Layer 3 (GitHub branch
protection). This hook is defense-in-depth, not the only line.

WIRING (worker launch):
  Export the project manifest path so the hook knows which raw paths to protect:
      export ORCH_MANIFEST=/abs/path/to/projects/<repo>.yml
  and register this script as a PreToolUse hook in the worker's settings, e.g.:
      {
        "hooks": {
          "PreToolUse": [
            { "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
              "hooks": [ { "type": "command",
                           "command": "/abs/path/to/host/hooks/raw-data-guard.py" } ] }
          ]
        }
      }
  (install.sh / new-project.sh own this wiring; ORCH_MANIFEST is set per dispatch.)
  The launcher may also export ORCH_LOGS_DIR (the orchestrator's own logs dir); it is an
  always-writable carveout so the checker can drop its verdict JSON there even when a
  self-hosting manifest's raw_resolved blankets the whole live clone (logs/ included).

FAIL-SAFE: if the manifest can't be resolved, the universal checks still run; only the
raw-path checks are skipped. A denial emits a PreToolUse `permissionDecision: deny`.
"""
import json
import os
import re
import shlex
import sys

# Mutating commands, split by which positional args are *write* targets:
#   ALL    — every positional is written/deleted (so reading-from is impossible here)
#   DEST   — only the last positional is the destination; earlier args are read-only sources
# `dd` (of=…) and shell redirections are handled separately.
MUTATING_ALL = {"rm", "mv", "shred", "truncate", "touch", "mkdir", "rmdir",
                "chmod", "chown", "tee"}
MUTATING_DEST = {"cp", "rsync", "install", "ln"}


def emit_deny(reason: str) -> None:
    """Block the tool call and feed `reason` back to the worker."""
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, sys.stdout)
    sys.exit(0)


def allow() -> None:
    """No decision == default behavior (allowed under bypassPermissions)."""
    sys.exit(0)


def canon(path: str, base: str) -> str:
    """Absolute, symlink-resolved path. Works on not-yet-existing leaves
    (realpath resolves the existing prefix, e.g. the data/raw symlink)."""
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(base, path)
    return os.path.realpath(path)


def is_under(candidate: str, prefix: str) -> bool:
    prefix = prefix.rstrip("/")
    return candidate == prefix or candidate.startswith(prefix + os.sep)


def is_blocked(target: str, cwd: str, protected: list[str], writable: list[str]) -> bool:
    """A write to `target` is blocked iff it lands under a protected raw prefix
    AND not under an explicit writable (output_paths) carveout."""
    c = canon(target, cwd)
    return any(is_under(c, p) for p in protected) and not any(is_under(c, w) for w in writable)


# ---- manifest --------------------------------------------------------------

def _manifest_reader():
    """Return (data_root, scalar, list_items) for the active manifest, or None.
    A tiny field reader (no yaml dependency) shared by the protected/writable
    prefix loaders."""
    manifest = os.environ.get("ORCH_MANIFEST")
    if not manifest or not os.path.isfile(manifest):
        return None
    try:
        text = open(manifest, encoding="utf-8").read()
    except OSError:
        return None

    def scalar(key: str):
        m = re.search(rf"^{key}:\s*(.+?)\s*(?:#.*)?$", text, re.MULTILINE)
        if not m:
            return None
        return m.group(1).strip().strip('"').strip("'")

    def list_items(key: str):
        block = re.search(rf"^{key}:\s*(?:#.*)?\n((?:[ \t]+-.*\n?)+)", text, re.MULTILINE)
        if not block:
            return []
        items = []
        for line in block.group(1).splitlines():
            m = re.match(r"\s*-\s*(.+?)\s*(?:#.*)?$", line)
            if m and m.group(1):
                items.append(m.group(1).strip().strip('"').strip("'"))
        return items

    data_root = scalar("data_root")
    data_root = os.path.expanduser(data_root) if data_root else os.getcwd()
    return data_root, scalar, list_items


def load_protected_prefixes() -> list[str]:
    """Canonical, symlink-resolved prefixes the worker must never write/delete."""
    r = _manifest_reader()
    if not r:
        return []
    data_root, scalar, list_items = r
    prefixes = set()

    raw_resolved = scalar("raw_resolved")
    if raw_resolved:
        prefixes.add(canon(raw_resolved, data_root))
    for rp in list_items("raw_paths"):
        # `.` means the whole data_root tree is raw.
        prefixes.add(canon("" if rp == "." else rp, data_root))
    return [p for p in prefixes if p]


def load_writable_prefixes() -> list[str]:
    """Canonical prefixes that stay WRITABLE even when nested under a protected
    raw tree — an explicit allow-carveout over the raw denylist. Three sources:

      1. `ORCH_LOGS_DIR` (env, set by the launcher) — the orchestrator's own
         logs dir. The checker writes its verdict JSON there; that dir is
         orchestrator RUNTIME STATE, never a project's raw data, so it must stay
         writable even when a self-hosting manifest's `raw_resolved` blankets the
         whole live clone (logs/ included). Applied regardless of manifest.
      2. manifest `output_paths` — needed when a repo's writable outputs live
         *inside* a shared data tree (e.g. per-survey outputs/ + results/ under a
         Dropbox-symlinked data dir): raw_resolved blanket-protects the tree;
         these dirs punch back through.
      3. manifest `derived_resolved` + `<data_root>/derived` — the shared derived
         tree (hub #38). derived/ is WRITABLE by design: a worker whose issue is
         "build the panel" must be able to write the artifact it is coding. Both
         forms are carved out because the worktree reaches it as
         `data/derived` (a symlink under data_root) while a write may resolve to
         the real shared path. Carved out from `derived_resolved` directly rather
         than relying on the author to also list data/derived in `output_paths` —
         a repo that set the key and forgot the list would have its worker denied
         mid-issue, which is exactly the failure this key exists to remove.

    Author responsibility: never list a path that overlaps real raw data. In
    particular, never point `derived_resolved` inside the raw tree."""
    prefixes = []
    logs_dir = os.environ.get("ORCH_LOGS_DIR")
    if logs_dir:
        prefixes.append(os.path.realpath(os.path.expanduser(logs_dir)))
    r = _manifest_reader()
    if r:
        data_root, scalar, list_items = r
        prefixes += [canon(p, data_root) for p in list_items("output_paths") if p]
        derived_resolved = scalar("derived_resolved")
        if derived_resolved:
            prefixes.append(canon(derived_resolved, data_root))
            prefixes.append(canon("derived", data_root))
    return prefixes


# ---- detection -------------------------------------------------------------

def split_subcommands(command: str) -> list[str]:
    """Split a shell command on operators so each piece can be parsed alone."""
    return [s for s in re.split(r"(?:\|\||&&|[;&|\n])", command) if s.strip()]


def redirect_targets(sub: str) -> list[str]:
    """File targets of output redirections (`>`, `>>`, `n>`, `&>`)."""
    return re.findall(r"(?:&|\d)?>>?\s*([^\s;|&<>()\"']+|\"[^\"]*\"|'[^']*')", sub)


def check_bash(command: str, protected: list[str], writable: list[str], cwd: str) -> None:
    for sub in split_subcommands(command):
        try:
            words = shlex.split(sub)
        except ValueError:
            words = sub.split()
        # Drop leading `VAR=value` assignments and a leading `rtk`/`env` wrapper.
        i = 0
        while i < len(words) and re.match(r"^[A-Za-z_]\w*=", words[i]):
            i += 1
        while i < len(words) and os.path.basename(words[i]) in ("rtk", "env", "command", "sudo", "nohup"):
            i += 1
        if i >= len(words):
            continue
        argv = words[i:]
        name = os.path.basename(argv[0])
        flags = "".join(a[1:] for a in argv[1:] if re.match(r"^-[A-Za-z]+$", a))
        positionals = [a for a in argv[1:] if not a.startswith("-")]

        # --- universal: destructive rm ---
        if name == "rm" and ("r" in flags.lower()) and ("f" in flags):
            emit_deny("Blocked `rm -rf` (recursive force delete). Remove targets explicitly, "
                      "or write to your worktree's output dir instead.")

        # --- universal: git push to main / force ---
        if name == "git" and "push" in argv:
            joined = " ".join(argv)
            if "--force" in argv or "--force-with-lease" in argv or re.search(r"(^|\s)-\w*f", joined):
                emit_deny("Blocked force-push. Open a PR; `main` is protected (Layer 3).")
            if "main" in argv or "master" in argv or re.search(r"\+\S*:", joined):
                emit_deny("Blocked push to main/master. Push your feature branch and open a PR.")

        if not protected:
            continue

        # --- raw-data: redirections into protected paths ---
        for tgt in redirect_targets(sub):
            tgt = tgt.strip("\"'")
            if is_blocked(tgt, cwd, protected, writable):
                emit_deny(f"Blocked write to read-only raw data: {tgt}. "
                          "Raw data is read-only; write outputs under data/derived/, data/results/ (or figures/, tables/).")

        # --- raw-data: mutating commands targeting protected paths ---
        sed_inplace = name == "sed" and any(a == "-i" or a.startswith("-i") for a in argv[1:])
        targets = []
        if name in MUTATING_ALL or sed_inplace:
            targets = positionals                       # every positional is written/deleted
        elif name in MUTATING_DEST and positionals:
            targets = positionals[-1:]                  # only the destination is written
        targets += [a[3:] for a in argv[1:] if a.startswith("of=")]   # dd of=FILE
        for arg in targets:
            if is_blocked(arg, cwd, protected, writable):
                emit_deny(f"Blocked `{name}` writing read-only raw data: {arg}. "
                          "Raw data is read-only; write outputs under data/derived/, data/results/ (or figures/, tables/).")


def check_file_write(path: str, protected: list[str], writable: list[str], cwd: str) -> None:
    if path and is_blocked(path, cwd, protected, writable):
        emit_deny(f"Blocked write to read-only raw data: {path}. "
                  "Raw data is read-only; write outputs under data/derived/, data/results/ (or figures/, tables/).")


# ---- entrypoint ------------------------------------------------------------

def main() -> None:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        allow()  # malformed input — don't wedge the worker; other layers hold.
        return

    tool = event.get("tool_name", "")
    ti = event.get("tool_input", {}) or {}
    cwd = event.get("cwd") or os.getcwd()
    protected = load_protected_prefixes()
    writable = load_writable_prefixes()

    if tool == "Bash":
        check_bash(ti.get("command", "") or "", protected, writable, cwd)
    elif tool in ("Write", "Edit", "MultiEdit"):
        check_file_write(ti.get("file_path", "") or "", protected, writable, cwd)
    elif tool == "NotebookEdit":
        check_file_write(ti.get("notebook_path", "") or "", protected, writable, cwd)

    allow()


if __name__ == "__main__":
    main()
