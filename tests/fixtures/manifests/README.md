# tests/fixtures/manifests

Throwaway manifests for `tests/offline/test-manifest-parser-conformance.sh`. They are
**not** real projects: every path is a fake `/nonexistent/...` value, nothing here is ever
opened, and no project data is touched. Each file isolates one shape of the manifest
list-block grammar that the deny-hook (`host/hooks/raw-data-guard.py`) and the launchers
(`yml_list()` in `bin/launch-worker.sh` / `bin/launch-checker.sh`) must read **identically**
(issue #76).

| Fixture | Shape under test |
|---|---|
| `continuation-comment.yml` | an entry comment continuing onto its own line, mid-block (the live california-pesticides shape) |
| `whole-line-comment.yml` | a whole-line comment at column 0, mid-block |
| `blank-line.yml` | a blank line mid-block |
| `trailing-comment.yml` | a trailing `#` comment on an entry |
| `quoted-entries.yml` | double- and single-quoted entries, incl. a path with spaces |
| `no-trailing-newline.yml` | final entry at EOF with **no trailing newline** (do not "fix" this file) |
| `block-boundary.yml` | end-of-block: a block must not run on into the next key's entries |

Adding a fixture needs no test edit — the test globs `*.yml` here and compares every
top-level key it finds.
