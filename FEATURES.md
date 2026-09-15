# Feature boundaries

This is an inventory of available behavior, not a promise of VS Code feature parity.
See [usage and safety](plugins/gitpanel/README.md) before performing disk writes.

## Available

- Native Files / Git sidebar, resource badge, branch status and error details.
- Primary-project enclosing-worktree discovery; staged, changed/untracked and
  conflict groups; refresh, keyboard navigation and native Files rendering.
- Read-only side-by-side HEAD/index/disk comparisons, block navigation, exact
  selection/copy and bounded raw fallback for unsupported text.
- Whole-file/group stage and unstage; global Stage All excludes conflicts.
- Multiline staged-only commits, normal hooks/signing and in-memory drafts.
- Local branch switching/creation with clean-state guards; known remote refs are
  informational, without fetching.
- **Confirmation-free** tracked whole-file discard and individual block revert,
  restoring from the index, not HEAD. Dirty/stale/metadata guards and protected
  native reload preserve editor buffers; disk changes have no editor undo.
- **Confirmation-free** recoverable whole-file untracked Remove, with a shared
  Undo glyph but distinct tooltip/consequences. Private repository-local recovery
  is not Trash or off-device backup; manual no-overwrite recovery only.
- Guarded refresh of eligible existing comparisons/clean Docs after tracked revert;
  newer or dirty owners are not overwritten. Reopen stale/raw snapshots explicitly.

## Experimental and disabled

Block and selected-line **stage/unstage** implementations exist for tests, but
`plugins/gitpanel/staging.lua` keeps `ENABLED = false`. They are not supported user
controls in this snapshot. Headless tests enable the flag only in memory; GUI
input/layout acceptance is still required before any separately authorized
production enablement. Selected-line **revert** is not implemented.

A measured whole-file tracked-discard optimization applies **only when the staging
QA flag is true**. No default-production, block-revert or Remove speedup is claimed.
Headless queue timing is not GUI click-to-paint performance evidence.

## Not provided

No fetch/pull/push, repository clone/publish UI, multi-repository picker, remote
checkout, stash, amend/history browser, merge/rebase orchestration, editable
conflict resolution, inline/word diff, GitHub/AI integration or plugin-registry
submission. No automatic recovery restore/purge or retention policy. No permanent
untracked deletion command and no staged/history revert.

## Verification boundary

Darwin is the runtime verification platform; Linux removal-helper contract coverage
is not full Linux editor support, and Windows support is not claimed. Automated
native-core tests use mocked rendering/process boundaries and newly owned real-Git
fixtures; they do not launch a GUI. Latest visual changes and experimental staging
lack fresh GUI mouse-click acceptance. See [TESTING.md](TESTING.md).
