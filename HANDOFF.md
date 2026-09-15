# Handoff: Issue #6

## Status

Issue #6 is fixed. Pull request #11 is open:

https://github.com/rajan-personal/lite-xl-gitpanel/pull/11

Branch: `fix/issue-6-redirected-git-environment`

## What changed

Git settings such as `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE` could redirect commands to the wrong repository. Audit found that sanitizing only the mutation helpers left panel discovery/status/diff using a different environment, so discard could still fail.

All panel Git commands and discard/remove/staging helpers now share `git_env.py`'s environment policy. The runner uses an isolated, shell-free Python exec wrapper so reads and writes agree on the selected worktree/index while preserving Git's PID, streams and exit status. Authentication and identity settings remain available to ordinary Git; local mutation helpers remove askpass.

**Requirement change:** Python 3.9+ on PATH is now required for all panel Git operations, not just destructive helpers.

Regressions exercise the production model and runner from root discovery through discard, with real foreign repositories, alternate indexes, missing gitdirs, object overrides and injected config. They verify that foreign repositories and both indexes remain unchanged. Ordinary status/stage/commit/switch integration also runs with redirected settings.

## Validation

All tests passed:

```sh
python3 -B plugins/gitpanel/tests/run.py
```

Result: 18 suites passed, 0 failed on a disposable snapshot of the exact staged PR contents (excluding unrelated Markdown work). The mixed working tree also passed all 19 suites before the final fixture-text cleanup. Optional installed SCM integration was explicitly skipped because `plugins/scm/util.lua` is unavailable. No real GUI acceptance is claimed.

## Next steps

- Review and merge PR #11.
- Do not discard the unrelated Markdown-preview work in `README.md`, `TESTING.md`, `plugins/gitpanel/init.lua`, `plugins/gitpanel/tests/run.py`, `plugins/gitpanel/tests/markdown_native.lua`, `plugins/gitpanel/markdown/` and `docs/markdown-preview.md`; it is intentionally left out of the PR.
