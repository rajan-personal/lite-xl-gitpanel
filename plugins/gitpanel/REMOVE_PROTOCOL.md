# Recoverable untracked-file helper contract

The editor integration supplies dirty-Doc, queue/generation and final-view refresh
guards in addition to this helper's filesystem/Git checks. Tracked discard and
experimental staging have separate helpers. Granular staging remains disabled.

## Invocation and byte protocol

Use `python3 -I <absolute remove.py> snapshot|remove ABS_ROOT REL_PATH`.
Only canonical absolute, nonsymlink repository roots and literal relative file
paths are accepted. Paths are argv values, never shell strings or pathspecs.
Python 3.9+ on macOS or Linux with exclusive rename support is required.

Fields use ASCII decimal byte length, newline, then exactly that many bytes;
there are no separators after the bytes. All successful stdout contains exactly
three fields. A caller must require exit status zero **and** a complete receipt.

- `snapshot`: no input. Output: `[file_bytes, four_digit_octal_mode, token]`.
  The token is 64 ASCII hex bytes and binds root/gitdir/parent identity, original
  path, complete raw index identity/bytes (or absence), HEAD, file identity/stat
  and bytes. Snapshot does not create a lock or recovery entry.
- `remove`: stdin is one framed token from `snapshot`, with no trailing bytes.
  Output: `[absolute_recovery_entry, original_relative_path, "removed"]`.
  This is a whole-file operation; no replacement text, selection, confirmation
  flag, staging-enabled flag or automatic Unstage is accepted.

Malformed/stale/unsupported requests and all operational failures exit nonzero,
with no success stdout. Staged-new `A` paths require **Unstage first**; a
HEAD-tracked path remains ineligible even after its index entry is removed.
There is no `absence`/restore/purge action. The caller must reacquire current state rather
than infer a valid final view from a saved token or from any nonzero result.

## Recovery and failure contract

Each removal exclusively creates `.git/gitpanel-recovery/entry-<128-bit random>/`
inside the normal repository's real `.git`. Existing recovery parents must be
nonsymlink, owned by the current user, mode 0700 and without access/default ACLs.
Entry collisions are errors,
never reuse or overwrite. Entries are private (0700), and contain:

- `snapshot`: checked pre-move bytes, with the original permission mode.
- `metadata.json` (0600): version 1, repository root, original relative `path`,
  integer `mode`, SHA-256, original `stat` tuple, token and content filenames.
  JSON escapes Unicode/surrogates; `os.fsencode(metadata["path"])` reconstructs
  the original filesystem path bytes.
- `content`: the original inode, moved by atomic **no-replace** rename. On success
  its identity, bytes, mode, owner/group and mtime have been checked after move.

Snapshot bytes/mode and metadata are written exclusively, read back and synced
before the move; directories are synced as well. The helper holds Git's actual
exclusive `index.lock` through resnapshot, move and verification, but never writes
or replaces the index. Cleanup checks the acquired lock identity and preserves
replacement locks already detected before cleanup. This is **cooperative Git
locking**, not unconditional atomic lock ownership: stat followed by unlink cannot
prevent a replacement between that check and unlink. Users/tools must not remove
or replace active locks. The replacement-lock test proves detection before cleanup,
not immunity to that final race. HEAD, raw index and current directories are
rechecked after the move.

There is no portable source compare-and-swap against external worktree writers.
If a late change/replacement is moved, `content` preserves what was moved and
`snapshot` preserves the checked earlier bytes. If the original path is recreated,
it is left untouched. **The helper never rolls back, unlinks recovered content,
or automatically purges anything.** It reports nonzero with `; recovery: <entry>`
on errors after entry creation, including uncertain post-move failure. Callers
must not treat failure as proof that the original path is still present. Failed
pre-move entries may be partial and need not have `content` or complete metadata.
After interruption, discover entries by listing `.git/gitpanel-recovery/`; inspect
metadata and both files before any manual recovery. No restore history UI exists.
Recovery survives helper errors, but is not a separate-device backup. External
renaming/deletion of repository/recovery directories can invalidate the printed
path; held descriptors prevent redirecting helper writes through swapped parents.

## Bounds and refusals

Only currently untracked, nonignored regular files with one link, no special
permission bits or file flags, and at most 2 MiB are eligible. The actual inode
move preserves its filesystem metadata; the extra snapshot promises bytes/mode,
not complete ACL/xattr replication. Symlinks, hardlinks, directories, special
files, traversal/protected `.git` components (case-insensitive), nested or linked
repositories, symlink ancestors, split/sparse indexes/worktrees and cross-device
moves are refused. Inherited Git environment overrides are ignored; explicit
repository and descriptor checks keep reads and moves bound to the selected
worktree. Raw index/Git output is also bounded to 2 MiB, Git subprocesses to 20
seconds, with a 60-second Git deadline.
No unsafe copy/delete or overwriting-rename fallback exists.

All Git reads use `--literal-pathspecs --no-optional-locks`, disable automatic
index refresh, fsmonitor and hooks, and use the current repository's Git state.
Tests use only newly owned disposable real-Git fixtures. Integration tests cover
native command/hit dispatch and dirty-buffer/final-view guards; renderer/transport
boundaries are mocked, not real GUI acceptance. Darwin is the verified editor
runtime; Linux helper contracts do not establish full editor support. Windows is
not claimed. Safe no-overwrite manual recovery instructions are in README.md.
