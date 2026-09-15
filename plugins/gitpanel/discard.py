#!/usr/bin/env python3
"""Bounded, literal, one-file worktree replacement. Never writes the index.
Invoked only by discard.lua; stdout is a length-prefixed byte protocol.
"""
import ctypes
import errno
import hashlib
import os
import stat
import selectors
import subprocess
import sys
import time

LIMIT = 2 * 1024 * 1024


def pack(values):
    return b"".join(str(len(v)).encode() + b"\n" + v for v in values)


def read_fields(stream, count):
    values = []
    for _ in range(count):
        size = int(stream.readline(20))
        assert 0 <= size <= LIMIT, "Discard input exceeds 2 MiB"
        value = stream.read(size)
        assert len(value) == size, "Incomplete discard input"
        values.append(value)
    assert not stream.read(1), "Unexpected discard input"
    return values


def plain_metadata(fd):
    """Refuse metadata we cannot preserve. macOS Python lacks os.listxattr."""
    assert not getattr(os.fstat(fd), "st_flags", 0), "File flags are not supported for discard"
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
        libc.flistxattr.restype = ctypes.c_ssize_t
        size = libc.flistxattr(fd, None, 0, 0)
        assert 0 <= size <= 4096, "Cannot inspect extended attributes"
        names = ctypes.create_string_buffer(max(1, size))
        assert libc.flistxattr(fd, names, size, 0) == size, "Extended attributes changed"
        assert names.raw[:size] in (b"", b"com.apple.provenance\0"), "Extended attributes other than com.apple.provenance are not supported for discard"
        provenance = None
        if size:
            libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
            libc.fgetxattr.restype = ctypes.c_ssize_t
            length = libc.fgetxattr(fd, b"com.apple.provenance", None, 0, 0, 0)
            assert 0 <= length <= 4096, "Cannot read provenance metadata"
            value = ctypes.create_string_buffer(max(1, length))
            assert libc.fgetxattr(fd, b"com.apple.provenance", value, length, 0, 0) == length, "Provenance metadata changed"
            provenance = value.raw[:length]
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_free.argtypes = [ctypes.c_void_p]
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED (Darwin sys/acl.h)
        if acl:
            libc.acl_free(acl)
            raise ValueError("ACLs are not supported for discard")
        assert ctypes.get_errno() == errno.ENOENT, "Cannot inspect file ACLs; discard refused"
        return provenance
    else:
        assert not os.listxattr(fd), "Extended attributes/ACLs are not supported for discard"


def main():
    # The model uses python3 -I. Refuse direct optimized invocation as well:
    # safety assertions must never be stripped by -O or PYTHONOPTIMIZE.
    if sys.flags.optimize:
        raise ValueError("Optimized Python is not supported for discard")
    action, root, path = sys.argv[1:]
    assert action in ("snapshot", "replace"), "Invalid discard action"
    root = os.path.realpath(root)
    parts = path.split("/")
    # The helper receives an environment inherited from the editor. Git's
    # GIT_* overrides must not redirect read-side preflight away from the
    # worktree whose bytes the replacement will later write. Keep this policy
    # aligned with remove.py and staging.py.
    assert all(p and p not in (".", "..") and p.casefold() != ".git" for p in parts), "Unsafe file path"
    allowed = {"GIT_TERMINAL_PROMPT", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ASKPASS", "GIT_AUTHOR_NAME",
               "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"}
    assert not any(k.startswith("GIT_") and k not in allowed for k in os.environ), "Redirected Git environment unsupported"
    env = os.environ.copy()
    # VS Code exports GIT_ASKPASS for authentication. Local discard never
    # contacts a remote, so do not let that UI hook affect the helper.
    env.pop("GIT_ASKPASS", None)
    env.update(GIT_TERMINAL_PROMPT="0", LC_ALL="C")

    deadline = time.monotonic() + 60  # Leave cleanup time before the editor's 120s limit.

    def git(*args):
        p = subprocess.Popen(["git", "--no-pager", "--literal-pathspecs", "--no-optional-locks",
                              "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull,
                              "-C", root, *args],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        output, errors, size = [], [], 0
        stop = min(deadline, time.monotonic() + 20)
        try:
            with selectors.DefaultSelector() as streams:
                streams.register(p.stdout, selectors.EVENT_READ, output)
                streams.register(p.stderr, selectors.EVENT_READ, errors)
                while streams.get_map():
                    assert time.monotonic() < stop, "Git preflight timed out; nothing discarded"
                    for key, _ in streams.select(min(0.1, max(0, stop - time.monotonic()))):
                        chunk = os.read(key.fileobj.fileno(), 16384)
                        if not chunk:
                            streams.unregister(key.fileobj)
                        else:
                            size += len(chunk)
                            assert size <= LIMIT, "Git source/output exceeds 2 MiB"
                            key.data.append(chunk)
            code = p.wait(timeout=max(0.01, stop - time.monotonic()))
            assert code == 0, b"".join(errors)[:4096].decode("utf-8", "replace") or "Git preflight failed"
            return b"".join(output)
        finally:
            if p.poll() is None:
                p.kill(); p.wait()
            p.stdout.close(); p.stderr.close()

    assert os.path.realpath(os.fsdecode(git("rev-parse", "--show-toplevel").rstrip(b"\n"))) == root, "Git root changed"
    def open_root():
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in root.split("/")[1:]:
                if component:
                    next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(fd); fd = next_fd
            return fd
        except Exception:
            os.close(fd)
            raise

    descriptors = [open_root()]
    try:
        for part in parts[:-1]:
            descriptors.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1]))
        parent, leaf = descriptors[-1], parts[-1]
        ancestors = [os.fstat(fd) for fd in descriptors]

        def identity(s):
            return repr((s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)).encode()

        def check_ancestors():
            # Recheck the live ancestor chain, not merely the held descriptors.
            fd = open_root()
            try:
                for i in range(len(descriptors)):
                    a, b = os.fstat(fd), ancestors[i]
                    assert (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino), "File directory changed"
                    if i < len(parts) - 1:
                        next_fd = os.open(parts[i], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        os.close(fd); fd = next_fd
            finally:
                os.close(fd)

        def snapshot():
            check_ancestors()
            index = git("ls-files", "--stage", "-z", "--", path)
            records = index.split(b"\0")
            assert len(records) == 2 and records[-1] == b"", "Discard requires one tracked, non-conflicted file; untracked deletion is not supported"
            metadata, indexed_path = records[0].split(b"\t", 1)
            mode, oid, stage = metadata.split()
            assert indexed_path == os.fsencode(path) and stage == b"0" and mode in (b"100644", b"100755"), "Symlink, conflict, submodule or unsupported index mode"
            # Check policy before status. These reads must fail closed without
            # allowing an unsupported filter/configuration to participate in
            # worktree inspection.
            attrs = git("check-attr", "-z", "filter", "working-tree-encoding", "ident", "text", "eol", "diff", "--", path)
            values = attrs.split(b"\0")
            assert all(v in (b"unspecified", b"unset") for v in values[2:-1:3]), "Git attributes/filters are not supported for discard; use Git externally"
            # --get-regexp returns 1 for unset keys; --get with --default does not.
            autocrlf = git("config", "--default", "false", "--get", "core.autocrlf").strip()
            assert autocrlf == b"false", "core.autocrlf conversion is not supported for discard; use Git externally"
            status = git("status", "--porcelain=v1", "-z", "--untracked-files=no", "--", path)
            assert status and status[1:2] in (b"M", b"D"), "No supported unstaged changes remain; refresh the Git view"
            assert status[0:1] not in (b"R", b"C", b"U"), "Rename or conflict is not supported"
            original = git("cat-file", "blob", os.fsdecode(oid))
            try:
                info = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                info = None
            if info is not None:
                assert stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "Symlink, hardlink or nonregular file: discard refused"
                assert not info.st_mode & 0o7000, "Special file permissions: discard refused"
                assert bool(info.st_mode & 0o111) == (mode == b"100755"), "Unstaged permission changes: discard refused"
                # O_NONBLOCK keeps a concurrent FIFO substitution from
                # suspending the editor's worker while the preflight opens it.
                fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                try:
                    assert identity(os.fstat(fd)) == identity(info), "File changed during preflight"
                    provenance = plain_metadata(fd)
                    with os.fdopen(os.dup(fd), "rb") as source:
                        modified = source.read(LIMIT + 1)
                    assert len(modified) <= LIMIT, "Disk source exceeds 2 MiB"
                    assert identity(os.fstat(fd)) == identity(info), "File changed during preflight"
                finally:
                    os.close(fd)
            else:
                modified, provenance = b"", None
            check_ancestors()
            token = hashlib.sha256(pack([index, original, modified, attrs, autocrlf, identity(info) if info else b"missing",
                                         repr([(s.st_dev, s.st_ino) for s in ancestors]).encode(), repr(provenance).encode()])).hexdigest().encode()
            return original, modified, token, info, mode, provenance

        original, modified, token, info, mode, provenance = snapshot()
        if action == "snapshot":
            sys.stdout.buffer.write(pack([original, modified, token]))
            return
        expected, replacement = read_fields(sys.stdin.buffer, 2)
        assert token == expected, "File or index changed since confirmation; refresh and retry"
        # Create exclusively in the held parent directory, never follow a leaf link.
        name = ".gitpanel-discard-" + os.urandom(16).hex()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            target_mode = stat.S_IMODE(info.st_mode) if info else (0o755 if mode == b"100755" else 0o644)
            if info:
                created = os.fstat(fd)
                if (created.st_uid, created.st_gid) != (info.st_uid, info.st_gid):
                    os.fchown(fd, info.st_uid, info.st_gid)
            os.fchmod(fd, target_mode)
            created_provenance = plain_metadata(fd)
            if info and created_provenance != provenance:
                assert sys.platform == "darwin" and provenance is not None, "Cannot preserve provenance metadata; discard refused"
                libc = ctypes.CDLL(None, use_errno=True)
                libc.fsetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
                assert libc.fsetxattr(fd, b"com.apple.provenance", provenance, len(provenance), 0, 0) == 0, "OS denied exact provenance preservation; discard refused"
                assert plain_metadata(fd) == provenance, "Cannot verify exact provenance preservation"
            with os.fdopen(os.dup(fd), "wb") as target:
                target.write(replacement); target.flush(); os.fsync(target.fileno())
            saved = os.fstat(fd)
            assert stat.S_IMODE(saved.st_mode) == target_mode, "Cannot preserve file permissions"
            if info:
                assert (saved.st_uid, saved.st_gid) == (info.st_uid, info.st_gid), "Cannot preserve file ownership"
                assert plain_metadata(fd) == provenance, "Cannot preserve exact file metadata"
            assert snapshot()[2] == expected, "File or index changed during discard preflight; nothing discarded"
            # There is no portable filesystem compare-and-swap. An external writer
            # can still race this final check/rename; no editor or Git index is saved.
            os.replace(name, leaf, src_dir_fd=parent, dst_dir_fd=parent)
        finally:
            os.close(fd)
            try:
                os.unlink(name, dir_fd=parent)
            except FileNotFoundError:
                pass
        sys.stdout.buffer.write(b"discarded\n")
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Discard refused: " + str(error), file=sys.stderr)
        sys.exit(1)
