#!/usr/bin/env python3
"""Index-only transaction. Hold Git's real index.lock through validation/install.
Private alternate index preserves unrelated entries; no worktree/ref commands.
"""
import hashlib
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import tempfile
import time
import runpy

# Isolated Python deliberately excludes the script directory from sys.path.
# Reuse the existing byte protocol without importing through user-site paths.
_protocol = runpy.run_path(str(Path(__file__).with_name("discard.py")))
LIMIT, pack, read_fields = (_protocol[name] for name in ("LIMIT", "pack", "read_fields"))


def main():
    if sys.flags.optimize:
        raise ValueError("Optimized Python is not supported for granular staging")
    action, root_arg, path, group = sys.argv[1:]
    assert action in ("snapshot", "replace") and group in ("changes", "staged", "untracked"), "Invalid staging request"
    parts = path.split("/")
    assert all(p and p not in (".", "..") and p.lower() != ".git" for p in parts) and "\0" not in path, "Unsafe path"
    root = Path(root_arg)
    assert root.is_absolute() and str(root.resolve()) == str(root), "Noncanonical root is unsupported"
    # Refuse linked worktrees and redirected index/object environments in this slice.
    allowed = ("GIT_TERMINAL_PROMPT", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ASKPASS",
               "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL")
    assert not any(k.startswith("GIT_") and k not in allowed for k in os.environ), "Redirected Git environment is unsupported"
    env = os.environ.copy()
    # VS Code exports GIT_ASKPASS for authentication. Local staging never
    # contacts a remote, so do not let that UI hook affect the helper.
    env.pop("GIT_ASKPASS", None)
    env.update(GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    deadline = time.monotonic() + 60

    def git(*args, data=None, index=None, worktree=None, allow_missing=False):
        child_env = env.copy()
        if index is not None:
            child_env["GIT_INDEX_FILE"] = str(index)
        location = ["-C", str(root)] if worktree is None else ["-C", str(worktree), "--git-dir=" + str(root / ".git"), "--work-tree=" + str(worktree)]
        argv = ["git", "--no-pager", "--literal-pathspecs", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull, *location, *args]
        # Input is bounded and supplied via a regular temporary stream: no pipe deadlock.
        with tempfile.TemporaryFile() as source:
            source.write(data or b""); source.seek(0)
            p = subprocess.Popen(argv, stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=child_env)
            out, err, size = [], [], 0
            try:
                with selectors.DefaultSelector() as streams:
                    streams.register(p.stdout, selectors.EVENT_READ, out)
                    streams.register(p.stderr, selectors.EVENT_READ, err)
                    while streams.get_map():
                        assert time.monotonic() < deadline, "Staging preflight timed out"
                        for key, _ in streams.select(0.1):
                            chunk = os.read(key.fileobj.fileno(), 16384)
                            if not chunk:
                                streams.unregister(key.fileobj)
                            else:
                                size += len(chunk)
                                assert size <= LIMIT, "Git output exceeds 2 MiB"
                                key.data.append(chunk)
                code = p.wait(timeout=max(.01, deadline-time.monotonic()))
                assert code == 0 or (allow_missing and code == 1), b"".join(err)[:4096].decode("utf-8", "replace") or "Git preflight failed"
                return b"".join(out)
            finally:
                if p.poll() is None:
                    p.kill(); p.wait()
                p.stdout.close(); p.stderr.close()

    def identity(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def read_regular(file, missing=False):
        try:
            fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            assert missing, "Required file is missing"
            return b"", None
        try:
            info = os.fstat(fd)
            assert stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and not info.st_mode & 0o7000, "Symlink, hardlink, special mode or nonregular file unsupported"
            with os.fdopen(os.dup(fd), "rb") as f:
                data = f.read(LIMIT + 1)
            assert len(data) <= LIMIT and identity(os.fstat(fd)) == identity(info), "File changed or exceeds 2 MiB"
            return data, info
        finally:
            os.close(fd)

    def ancestors(file):
        values = []
        for directory in reversed(file.parents):
            info = directory.lstat()
            assert stat.S_ISDIR(info.st_mode), "Symlink/non-directory ancestor unsupported"
            values.append((str(directory), info.st_dev, info.st_ino))
        return values

    index_path = root / ".git" / "index"
    tree_path = root.joinpath(*parts)
    initial_dirs = ancestors(index_path), ancestors(tree_path)
    assert git("rev-parse", "--show-toplevel").rstrip(b"\n") == os.fsencode(root), "Git root changed"
    assert git("rev-parse", "--absolute-git-dir").rstrip(b"\n") == os.fsencode(root / ".git"), "Linked/redirected Git directory unsupported"
    assert not git("rev-parse", "--shared-index-path").strip(), "Split index unsupported"
    for key in ("core.sparseCheckout", "index.sparse"):
        assert git("config", "--bool", "--default", "false", "--get", key).strip() == b"false", "Sparse index/worktree unsupported"

    def snapshot():
        assert (ancestors(index_path), ancestors(tree_path)) == initial_dirs, "Root/directory identity changed"
        index_bytes, index_info = read_regular(index_path, True)
        head = git("rev-parse", "--verify", "--quiet", "HEAD", allow_missing=True).strip()
        index_entry = git("ls-files", "--stage", "-z", "--", path)
        head_entry = git("ls-tree", "-z", os.fsdecode(head), "--", path) if head else b""

        def entry(record, tree=False):
            if not record:
                return None, b""
            records = record.split(b"\0")
            assert len(records) == 2 and not records[1], "Conflicted/multiple entries unsupported"
            metadata, name = records[0].split(b"\t", 1)
            a, b, c = metadata.split()
            mode, oid = (a, c) if tree else (a, b)
            assert name == os.fsencode(path) and mode in (b"100644", b"100755") and (b == b"blob" if tree else c == b"0"), "Unsupported index/HEAD mode or conflict"
            return mode, git("cat-file", "blob", os.fsdecode(oid))

        imode, indexed = entry(index_entry)
        hmode, committed = entry(head_entry, True)
        assert imode or hmode or group == "untracked", "File is no longer tracked"
        assert not (imode and hmode and imode != hmode), "Mode changes unsupported"
        flags = git("ls-files", "-v", "-z", "--", path)
        assert not flags or flags.startswith(b"H "), "Assume-unchanged/skip-worktree entries unsupported"
        attrs = []
        for cached in (False, True):
            value = git("check-attr", *( ["--cached"] if cached else []), "-z", "filter", "working-tree-encoding", "ident", "text", "eol", "diff", "--", path)
            assert all(v in (b"unspecified", b"unset") for v in value.split(b"\0")[2:-1:3]), "Git attributes/filters unsupported"
            attrs.append(value)
        autocrlf = git("config", "--default", "false", "--get", "core.autocrlf").strip()
        assert autocrlf == b"false", "core.autocrlf conversion unsupported"
        # Never use worktree status/diff here: even an unrelated dirty path can
        # execute a clean/process filter. Rename/copy detection reads blobs only.
        renamed = git("diff", "--cached", "--raw", "-z", "--find-renames", "--find-copies",
                      "--diff-filter=RC", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--")
        records = renamed.split(b"\0")
        assert records[-1] == b"" and (len(records)-1) % 3 == 0, "Invalid rename/copy records"
        for n in range(0, len(records)-1, 3):
            assert os.fsencode(path) not in records[n+1:n+3], "Rename/copy/conflict unsupported"
        working, info = read_regular(tree_path, True)
        if group == "untracked":
            assert git("ls-files", "--others", "--exclude-standard", "-z", "--", path) == os.fsencode(path)+b"\0", "Source is ignored or no longer untracked"
        elif group == "changes":
            assert imode, "Source is no longer in the requested group"
        mode = imode or hmode or b"100644"
        if info:
            disk_mode = b"100755" if info.st_mode & stat.S_IXUSR else b"100644"
            assert not (imode or hmode) or disk_mode == mode, "Worktree mode change unsupported"
            mode = disk_mode
        assert group != "untracked" or (not imode and not hmode and info), "Untracked source changed"
        original, modified = (committed, indexed) if group == "staged" else (indexed, working)
        for text in (original, modified):
            assert b"\0" not in text, "Binary source unsupported"
            text.decode("utf-8")
            assert len(text.splitlines()) <= 50000 and all(len(line) <= 16384 for line in text.split(b"\n")), "Text limits exceeded"
        assert original != modified, "No textual changes remain"
        token = hashlib.sha256(pack([index_bytes, repr(identity(index_info) if index_info else None).encode(), head, index_entry, head_entry, group.encode(), original, modified, working, repr(identity(info) if info else None).encode(), *attrs, autocrlf, repr(initial_dirs).encode()])).hexdigest().encode()
        # Empty and absent are distinct: only complete target reconstruction removes an entry.
        target_absent = not hmode if group == "staged" else info is None
        return original, modified, token, mode, target_absent, index_bytes, index_info

    if action == "snapshot":
        values = snapshot()
        sys.stdout.buffer.write(pack(values[:3]))
        return
    expected, replacement = read_fields(sys.stdin.buffer, 2)
    # Hold the Git directory by descriptor, opening every ancestor no-follow.
    # Lock creation, installation and cleanup cannot be redirected via symlinks.
    gitdir = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in (root / ".git").parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=gitdir)
            os.close(gitdir); gitdir = next_fd
        assert (ancestors(index_path), ancestors(tree_path)) == initial_dirs, "Root/directory identity changed"
        assert (os.fstat(gitdir).st_dev, os.fstat(gitdir).st_ino) == initial_dirs[0][-1][1:], "Git directory changed"
        fd = os.open("index.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=gitdir)
    except Exception:
        os.close(gitdir)
        raise
    owned_lock = os.fstat(fd)
    installed = False
    try:
        original, modified, token, mode, absent, index_bytes, index_info = snapshot()
        assert token == expected, "Stale source/index/HEAD: reopen diff"
        target = original if group == "staged" else modified
        with tempfile.TemporaryDirectory(prefix="gitpanel-index-", dir=root / ".git") as tmp:
            alternate = Path(tmp) / "index"
            if index_info:
                alternate.write_bytes(index_bytes)
            if absent and replacement == target:
                oid, entry_mode = b"0" * len(git("hash-object", "--stdin", data=b"").strip()), b"0"
            else:
                oid = git("hash-object", "-w", "--stdin", "--no-filters", data=replacement).strip()
                entry_mode = mode
            # Writing an index can hash unrelated racy-stat entries through clean
            # filters. Expose no real worktree files to this private index writer;
            # both cwd and --work-tree must be empty (racy reads are cwd-relative).
            # All snapshot guards still read the actual root and real index.
            empty_worktree = Path(tmp) / "empty-worktree"
            empty_worktree.mkdir()
            git("update-index", "--add", "--remove", "-z", "--index-info", data=entry_mode+b" "+oid+b"\t"+os.fsencode(path)+b"\0", index=alternate, worktree=empty_worktree)
            updated, _ = read_regular(alternate)
            lock_info = os.stat("index.lock", dir_fd=gitdir, follow_symlinks=False)
            assert (lock_info.st_dev, lock_info.st_ino) == (os.fstat(fd).st_dev, os.fstat(fd).st_ino), "Index lock changed"
            os.fchmod(fd, stat.S_IMODE(index_info.st_mode) if index_info else 0o644)
            with os.fdopen(os.dup(fd), "wb") as output:
                output.write(updated); output.flush(); os.fsync(output.fileno())
            assert snapshot()[2] == expected, "Source/index/HEAD changed during staging"
            lock_info = os.stat("index.lock", dir_fd=gitdir, follow_symlinks=False)
            assert (lock_info.st_dev, lock_info.st_ino) == (owned_lock.st_dev, owned_lock.st_ino), "Index lock changed"
            # Git-compliant index writers cannot race this lock. External worktree/ref
            # writers can race the final validation; neither worktree nor refs are written.
            os.replace("index.lock", "index", src_dir_fd=gitdir, dst_dir_fd=gitdir)
            installed = True
        sys.stdout.buffer.write(b"index updated\n")
    finally:
        os.close(fd)
        try:
            if not installed:
                try:
                    current_lock = os.stat("index.lock", dir_fd=gitdir, follow_symlinks=False)
                    if (current_lock.st_dev, current_lock.st_ino) == (owned_lock.st_dev, owned_lock.st_ino):
                        os.unlink("index.lock", dir_fd=gitdir)
                except FileNotFoundError:
                    pass
        finally:
            os.close(gitdir)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Granular staging refused: " + str(error), file=sys.stderr)
        sys.exit(1)
