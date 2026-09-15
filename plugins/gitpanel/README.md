# Git panel usage and safety

See the [project README](../../README.md) for requirements, supported platforms
and installation. Copy this directory, not the repository root, to
`USERDIR/plugins/gitpanel` with `init.lua` directly inside it.

## Supported workflow

The native Files / Git sidebar shows the primary project's enclosing worktree,
including paths outside a nested project folder. Sections collapse independently;
partially staged files appear in both Staged Changes and Changes. The bottom
branch indicator works independently of the sidebar. Status refreshes periodically
and on explicit Refresh; failed-operation details remain available.

Row and group **+ / −** actions stage saved whole-file contents or unstage index
entries. Neither changes editor buffers. Global Stage All excludes conflicts;
Conflicts + explicitly marks the disk version resolved without editing markers.
Commit uses **only the index**, preserves comment-prefixed message lines and runs
normal local hooks/signing. There is no push, implicit staging or auto-stash.
Hooks can fail or modify Git state. No interactive signing/password terminal is
provided; inspect status before retrying a failed/timed-out commit.

The multiline commit draft survives view/project switches in memory, not exit.
Branch search includes local and already-known remote refs, with no fetch.
Switch/create local branches refuses dirty Git state, untracked files or unsaved
editor buffers. Remote refs are informational; unborn branches require a first
commit before switching/creating branches.

## Comparisons and destructive actions

Comparisons are one read-only owner tab, Original left and Modified right:
HEAD → index for staged, index → saved disk for tracked changes, empty → disk
for untracked files. Both sides share scrolling; select/copy either source,
navigate hunks with Prev/Next, or open Raw. Renames use old/new paths. Metadata-only
comparisons have no invented hunks. Binary, conflict, submodule and other
unsupported text uses an explicit raw fallback where available.

**The shared bent Undo glyph is not a promise of editor undo. Read its tooltip.**

- **Discard unstaged changes** on a tracked Changes row restores the whole file
  from the captured **index**, not HEAD. **Revert unstaged change block** restores
  just that block and keeps neighboring edits. Both write disk immediately,
  **without confirmation**, leave staged content/history unchanged and have no
  tracked-content recovery or editor undo for the disk write.
- **Remove untracked file (recoverable)** on an eligible U row moves the entire
  file to private repository-local recovery, **without confirmation**. Eligible
  whole-file all-addition hunks also offer this explicitly whole-file action.
  Empty/binary eligible files can use the row action. **Staged A requires Unstage
  first**; selected-change undo never deletes a new file.
- **Revert Selected Change** selects a block, not arbitrary selected-line revert.
  Staged comparisons do not expose destructive revert. Experimental block/line
  stage and unstage remain disabled; do not change their gate for normal use.

Dirty buffers (conservatively including unrelated/untitled buffers), stale tokens,
changed roots or unsupported paths refuse writes. Successful tracked operations
refresh eligible invocation-captured clean Docs and existing comparisons without
new tabs/focus changes. Newer browse/selection/generation or edits prevent automatic
replacement. Skipped textual comparisons show **STALE — reopen** and stay inert;
raw fallback snapshots may have no visible stale header, so reopen explicitly.
After Remove, normal Docs are not closed, reloaded from missing paths or marked
clean: their text/undo is retained. Only still-owned, revalidated comparisons can
show **File removed · no current changes**.

## Safe manual recovery (no overwrite)

Remove is **not system Trash or an off-device backup**. Successful receipts log
an absolute `.git/gitpanel-recovery/entry-…` location. **No receipt or an error does
not prove the source is still present.** Inspect the original path and recovery
directories before retrying. Complete entries contain `metadata.json`, a checked
pre-move `snapshot` and moved `content`; these may differ after a late-change
failure. Interrupted entries may be partial. Never delete an active `index.lock`.

Inspect both files and metadata first. To copy a checked snapshot, choose a **new
absolute destination in a trusted existing directory**, never an existing source
file. Adapt this example manually; the plugin does not execute it:

```python
from pathlib import Path
import json, os, shutil
entry = Path("/absolute/repository/.git/gitpanel-recovery/entry-REPLACE")
destination = Path("/absolute/trusted-directory/recovered-new-name")
metadata = json.loads((entry / "metadata.json").read_text())
with (entry / "snapshot").open("rb") as source, destination.open("xb") as target:
    shutil.copyfileobj(source, target)
    os.fchmod(target.fileno(), metadata["mode"])
```

Exclusive `xb` refuses an existing file or symlink. A failed copy can leave a
partial new destination: inspect it and choose another name, not overwrite.
For a late-change entry deliberately choose `content` only after inspection.
Keep recovery entries until verified. There is **no restore/purge/history UI,
retention policy or automatic rollback**. Storage may contain secrets; do not
publish or share it. Snapshot recovery promises bytes/mode, not full ACL/xattr
replication. External renames/deletion can stale logged paths. See the exact
[removal helper contract](REMOVE_PROTOCOL.md).

## Limits and failure behavior

- Plugin Git jobs are serialized and project-generation-bound. An already-started
  mutation finishes in its original worktree even if you switch projects. Other
  tools can still change Git state concurrently. Refresh/reopen after external
  edits; never assume errors or timeouts prove nothing changed.
- Git receives argv, not shell strings; literal mutation paths use NUL stdin.
  Whitespace, newlines and pathspec-like names are escaped only for display.
  Ordinary Git jobs cap output at 8 MiB and time out at 120 seconds. Diagnostics
  may contain repository paths or Git/hook output: review before sharing them.
- Tracked discard is deliberately narrower than browsing: tracked unmerged
  regular text, unchanged executable mode, ordinary existing parents and exact
  captured index/source identity. Symlinks/ancestors, hardlinks, renames/copies,
  submodules, conflicts, binaries/non-UTF-8, special modes/flags, ACLs and
  unsupported xattrs refuse. Git conversion attributes/filters and `core.autocrlf`
  refuse; raw CRLF and missing-final-newline text without conversion are supported.
  Ownership/ordinary permissions are preserved; inherited Git redirect
  overrides are ignored; on macOS only `com.apple.provenance` is allowed among
  xattrs, with verified exact preservation.
- Every panel Git command (including discovery, status, diff, stage and commit)
  uses the same inherited-environment policy as the Python mutation helpers.
  Redirecting `GIT_*` overrides and injected config are ignored; authentication,
  author/committer identity and explicit global/no-system config settings remain.
  Ordinary Git retains `GIT_ASKPASS`; local mutation helpers remove it. Python
  3.9+ is required for all operations. The shell-free wrapper execs Git, preserving
  the runner's PID, input/output streams, exit status and timeout handling.
- Discard's isolated Python helper revalidates, uses no-follow directory
  descriptors and a bounded same-directory temporary file, then atomically
  replaces one literal leaf. It never writes the index. Output/preflight is
  bounded to 2 MiB with a 60-second helper deadline. A forced kill may leave a
  `.gitpanel-discard-*` temporary file; inspect externally, never broad-clean it.
  No OS-level compare-and-swap against external worktree/index writers is claimed.
- Reload protection guards affected native Docs at the actual reload boundary,
  including queued autoreload. Dirty text/undo is preserved and an explicit
  Cancel-default protected-reload prompt may follow a normal File Changed prompt.
  Changes while that approval is pending invalidate it; no automatic retry occurs.
  This is separate from the **confirmation-free destructive Git action** itself.
- Text comparison limits: **2 MiB/source, 50,000 lines/source, 16 KiB/line**.
  Oversized/raw-unsupported data is refused, not truncated as if complete. No
  soft wrapping, source editing, word diff, multi-cursor, source search or merge
  editor is provided. Comparisons are snapshots, not continuously live views.
- Remove accepts only currently untracked, nonignored, single-link regular files
  up to 2 MiB; symlinks, directories, nested/linked repositories, sparse/split
  indexes and unsafe metadata/layouts refuse. Inherited Git environment
  overrides are ignored so they cannot redirect the operation away from the
  selected worktree. No overwriting-rename or copy/delete fallback exists.
  Cooperative `index.lock`
  protects Git writers, not arbitrary filesystem writers. Recovery errors can
  occur after the move; inspect rather than assume rollback.

## Keyboard and palette

Shortcuts use **Control**, not macOS Command, unless stated otherwise. Commands
are also listed under **Git Panel** (`git-panel:*`) in the command palette.

| Shortcut | Action |
| --- | --- |
| Ctrl+Shift+G | Toggle Files/Git and focus sidebar |
| Ctrl+Alt+R | Refresh |
| Ctrl+Alt+B | Search branches |
| Ctrl+Alt+M | Focus commit draft |
| Ctrl+Return | Commit staged when Git/sidebar composer focused |
| Escape | Leave composer / focus list |
| Up / Down | Select list row |
| Left / Right | Collapse / expand section |
| Return / Space | Open selected diff / toggle header |
| +, =, − (minus key) | Apply selected row's displayed index action |
| Alt+Down / Alt+Up | Next / previous diff block |
| Tab in comparison | Select other source side |
| Ctrl+C / Cmd+C | Copy selected source text, never alignment gaps |
| Ctrl+A / Cmd+A | Select entire active source |

Comparisons support caret/Shift-selection, mouse selection, shared vertical and
horizontal scrolling. Native close/tab navigation/splitting acts on the single
owner tab. Read-only snapshots are not restored across sessions.

See [TESTING.md](../../TESTING.md) for headless coverage and platform/resource
assumptions. Headless render/hit tests are not real GUI mouse-click verification.
