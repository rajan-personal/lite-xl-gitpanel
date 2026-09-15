#!/usr/bin/env python3
"""R04A only: snapshot/remove one untracked regular file, with private recovery.
See REMOVE_PROTOCOL.md. No editor integration, index writes, restore or purge.
"""
import ctypes
import errno
import hashlib
import json
import os
import selectors
import stat
import subprocess
import sys
import time
from contextlib import ExitStack

LIMIT = 2 * 1024 * 1024
RECOVERY = "gitpanel-recovery"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def pack(values):
    return b"".join(str(len(v)).encode() + b"\n" + v for v in values)


def read_token(stream):
    size = stream.readline(20)
    require(size == b"64\n", "Expected one 64-byte snapshot token")
    token = stream.read(64)
    require(len(token) == 64 and not stream.read(1), "Invalid snapshot token input")
    return token


def identity(info):
    return (info.st_dev, info.st_ino)


def version(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def open_directory(path):
    """Absolute no-follow walk, including ancestors above the repository root."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.split("/")[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_regular(parent, leaf):
    info = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "Requires a regular, nonlinked file")
    require(not info.st_mode & 0o7000, "Special permissions unsupported")
    require(not getattr(info, "st_flags", 0), "File flags unsupported")
    fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        require(version(os.fstat(fd)) == version(info), "File changed while opening")
        with os.fdopen(os.dup(fd), "rb") as stream:
            content = stream.read(LIMIT + 1)
        require(len(content) <= LIMIT, "File exceeds 2 MiB")
        require(version(os.fstat(fd)) == version(info), "File changed while reading")
        require(version(os.stat(leaf, dir_fd=parent, follow_symlinks=False)) == version(info), "File replaced while reading")
        return content, info
    finally:
        os.close(fd)


def private_permissions(fd):
    """Mode 0700 alone does not exclude inherited macOS ACL grants."""
    info = os.fstat(fd)
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, "Recovery directory must be private and owned")
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_free.argtypes = [ctypes.c_void_p]
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
        if acl:
            libc.acl_free(acl)
            raise ValueError("Recovery directory ACLs unsupported")
        require(ctypes.get_errno() == errno.ENOENT, "Cannot verify private recovery ACLs")
    else:
        require(not any(name.startswith("system.posix_acl_") for name in os.listxattr(fd)), "Recovery directory ACLs unsupported")


def exclusive_move(source_fd, source, destination_fd, destination):
    """Atomic no-replace rename; deliberately no unsafe portable fallback."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        flag = 4  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename = libc.renameat2
        flag = 1  # RENAME_NOREPLACE
    else:
        raise ValueError("Atomic exclusive rename unsupported on this platform")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(source_fd, os.fsencode(source), destination_fd, os.fsencode(destination), flag):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


class Repository:
    def __init__(self, root, path, stack):
        require(os.path.isabs(root) and os.path.normpath(root) == root and root != "/", "Noncanonical root unsupported")
        parts = path.split("/")
        require(all(p and p not in (".", "..") and p.casefold() != ".git" and "\x00" not in p for p in parts), "Unsafe relative path")
        allowed = {"GIT_TERMINAL_PROMPT", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ASKPASS", "GIT_AUTHOR_NAME",
                   "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"}
        require(not any(k.startswith("GIT_") and k not in allowed for k in os.environ), "Redirected Git environment unsupported")
        self.env = os.environ.copy()
        # VS Code exports GIT_ASKPASS for authentication. Local removal never
        # contacts a remote, so do not let that UI hook affect the helper.
        self.env.pop("GIT_ASKPASS", None)
        self.env.update(GIT_TERMINAL_PROMPT="0", LC_ALL="C")
        self.root, self.path, self.leaf = root, path, parts[-1]
        self.deadline = time.monotonic() + 60
        self.stack = stack
        self.root_fd = self.hold(open_directory(root))
        self.git_fd = self.hold(os.open(".git", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root_fd))
        self.chain = [(root, identity(os.fstat(self.root_fd))), (root + "/.git", identity(os.fstat(self.git_fd)))]
        self.parent = self.root_fd
        directory = root
        for part in parts[:-1]:
            directory += "/" + part
            self.parent = self.hold(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.parent))
            self.chain.append((directory, identity(os.fstat(self.parent))))
            try:
                os.stat(".git", dir_fd=self.parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("Nested repository unsupported")
        self.source_chain = list(self.chain)

    def hold(self, fd):
        self.stack.callback(os.close, fd)
        return fd

    def check_directories(self):
        for path, expected in self.chain:
            fd = open_directory(path)
            try:
                require(identity(os.fstat(fd)) == expected, "Directory identity changed: " + path)
            finally:
                os.close(fd)

    def git(self, *args, allowed=(0,)):
        command = ["git", "--no-pager", "--literal-pathspecs", "--no-optional-locks", "-c", "diff.autoRefreshIndex=false",
                   "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull, "-C", self.root, *args]
        p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        output, errors, size = [], [], 0
        stop = min(self.deadline, time.monotonic() + 20)
        try:
            with selectors.DefaultSelector() as streams:
                streams.register(p.stdout, selectors.EVENT_READ, output)
                streams.register(p.stderr, selectors.EVENT_READ, errors)
                while streams.get_map():
                    require(time.monotonic() < stop, "Git preflight timed out")
                    for key, _ in streams.select(0.1):
                        data = os.read(key.fileobj.fileno(), 16384)
                        if not data:
                            streams.unregister(key.fileobj)
                        else:
                            size += len(data)
                            require(size <= LIMIT, "Git output exceeds 2 MiB")
                            key.data.append(data)
            code = p.wait(timeout=max(0.01, stop - time.monotonic()))
            require(code in allowed, b"".join(errors)[:4096].decode("utf-8", "replace") or "Git preflight failed")
            return b"".join(output)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
            p.stdout.close()
            p.stderr.close()

    def git_state(self, absent=False):
        self.check_directories()
        require(self.git("rev-parse", "--show-toplevel").rstrip(b"\n") == os.fsencode(self.root), "Git root changed")
        require(self.git("rev-parse", "--absolute-git-dir").rstrip(b"\n") == os.fsencode(self.root + "/.git"), "Redirected gitdir unsupported")
        require(self.git("rev-parse", "--git-common-dir").strip() == b".git", "Linked/shared repository unsupported")
        require(not self.git("rev-parse", "--shared-index-path").strip(), "Split index unsupported")
        for key in ("core.sparseCheckout", "index.sparse"):
            require(self.git("config", "--bool", "--default", "false", "--get", key).strip() == b"false", "Sparse repository unsupported")
        require(not self.git("ls-files", "--stage", "-z", "--", self.path), "Index-tracked file: Unstage first")
        head = self.git("rev-parse", "--verify", "--quiet", "HEAD", allowed=(0, 1)).strip()
        if head:
            require(not self.git("ls-tree", "-z", os.fsdecode(head), "--", self.path), "HEAD-tracked file unsupported")
        expected_status = b"" if absent else b"?? " + os.fsencode(self.path) + b"\0"
        require(self.git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--", self.path)
                == expected_status, "File is not currently " + ("absent" if absent else "untracked and nonignored"))
        try:
            index, info = read_regular(self.git_fd, "index")
            index_state = pack([index, repr(version(info)).encode()])
        except FileNotFoundError:
            index_state = b"absent"
        self.check_directories()
        return head, index_state

    def snapshot(self):
        head, index = self.git_state()
        self.last_git_state = (head, index)
        content, info = read_regular(self.parent, self.leaf)
        require(info.st_dev == os.fstat(self.git_fd).st_dev, "Cross-filesystem removal unsupported")
        self.check_directories()
        token = hashlib.sha256(pack([os.fsencode(self.root), os.fsencode(self.path), repr(self.source_chain).encode(),
                                     head, index, content, repr(version(info)).encode()])).hexdigest().encode()
        return content, info, token

    def private_directory(self, parent, name, create=True):
        if create:
            os.mkdir(name, 0o700, dir_fd=parent)
        fd = self.hold(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent))
        info = os.fstat(fd)
        private_permissions(fd)
        require(info.st_dev == os.fstat(self.git_fd).st_dev, "Cross-filesystem recovery unsupported")
        return fd

    def write_checked(self, parent, name, content, mode):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            with os.fdopen(os.dup(fd), "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fchmod(fd, mode)
                os.fsync(fd)
        finally:
            os.close(fd)
        saved, info = read_regular(parent, name)
        require(saved == content and stat.S_IMODE(info.st_mode) == mode, "Recovery write verification failed")

    def remove(self, expected):
        require(self.snapshot()[2] == expected, "Stale snapshot; refresh and retry")
        lock = os.open("index.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.git_fd)
        owned = identity(os.fstat(lock))
        recovery_path = None
        try:
            content, info, token = self.snapshot()
            require(token == expected, "Changed under index lock; refresh and retry")
            expected_git = self.last_git_state
            try:
                recovery = self.private_directory(self.git_fd, RECOVERY)
            except FileExistsError:
                recovery = self.private_directory(self.git_fd, RECOVERY, create=False)
            self.chain.append((self.root + "/.git/" + RECOVERY, identity(os.fstat(recovery))))
            name = "entry-" + os.urandom(16).hex()
            entry = self.private_directory(recovery, name)
            recovery_path = self.root + "/.git/" + RECOVERY + "/" + name
            self.chain.append((recovery_path, identity(os.fstat(entry))))
            metadata = {"version": 1, "root": self.root, "path": self.path, "mode": stat.S_IMODE(info.st_mode),
                        "sha256": hashlib.sha256(content).hexdigest(), "stat": list(version(info)),
                        "token": token.decode(), "snapshot": "snapshot", "moved_content": "content"}
            self.write_checked(entry, "snapshot", content, stat.S_IMODE(info.st_mode))
            self.write_checked(entry, "metadata.json", (json.dumps(metadata, ensure_ascii=True, sort_keys=True) + "\n").encode(), 0o600)
            os.fsync(entry)
            os.fsync(recovery)
            os.fsync(self.git_fd)
            require(self.snapshot()[2] == expected, "Changed before move; original retained")
            saved, saved_info = read_regular(entry, "snapshot")
            require(saved == content and stat.S_IMODE(saved_info.st_mode) == stat.S_IMODE(info.st_mode), "Recovery snapshot changed")
            saved_metadata, metadata_info = read_regular(entry, "metadata.json")
            require(saved_metadata == (json.dumps(metadata, ensure_ascii=True, sort_keys=True) + "\n").encode()
                    and stat.S_IMODE(metadata_info.st_mode) == 0o600, "Recovery metadata changed")
            private_permissions(recovery)
            private_permissions(entry)
            self.check_directories()
            require(identity(os.stat("index.lock", dir_fd=self.git_fd, follow_symlinks=False)) == owned, "Index lock ownership lost")
            # No compare-and-swap exists for an externally writable source. Preserve
            # both the checked snapshot and whatever the exclusive rename moves.
            exclusive_move(self.parent, self.leaf, entry, "content")
            os.fsync(entry)
            os.fsync(self.parent)
            moved, moved_info = read_regular(entry, "content")
            require(moved == content and identity(moved_info) == identity(info)
                    and (moved_info.st_mode, moved_info.st_uid, moved_info.st_gid, moved_info.st_mtime_ns)
                    == (info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns), "Late file change; moved bytes preserved")
            self.check_directories()
            try:
                os.stat(self.leaf, dir_fd=self.parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("Original path recreated; preserved without overwrite")
            require(self.git_state(absent=True) == expected_git, "Git state changed after move; recovery retained")
            require(identity(os.stat("index.lock", dir_fd=self.git_fd, follow_symlinks=False)) == owned, "Index lock ownership lost after move")
            return [os.fsencode(recovery_path), os.fsencode(self.path), b"removed"]
        except BaseException as error:
            if recovery_path:
                raise RuntimeError(str(error) + "; recovery: " + recovery_path) from error
            raise
        finally:
            try:
                try:
                    current = os.stat("index.lock", dir_fd=self.git_fd, follow_symlinks=False)
                    if identity(current) == owned:
                        os.unlink("index.lock", dir_fd=self.git_fd)
                except FileNotFoundError:
                    pass
            except Exception as error:
                raise RuntimeError("Lock cleanup failed: " + str(error) + ("; recovery: " + recovery_path if recovery_path else "")) from error
            finally:
                os.close(lock)


def main():
    require(not sys.flags.optimize, "Optimized Python unsupported")
    require(len(sys.argv) == 4 and sys.argv[1] in ("snapshot", "remove"), "Usage: remove.py snapshot|remove ABS_ROOT REL_PATH")
    action, root, path = sys.argv[1:]
    expected = read_token(sys.stdin.buffer) if action == "remove" else None
    with ExitStack() as stack:
        repo = Repository(root, path, stack)
        if action == "snapshot":
            content, info, token = repo.snapshot()
            result = [content, ("%04o" % stat.S_IMODE(info.st_mode)).encode(), token]
        else:
            result = repo.remove(expected)
    sys.stdout.buffer.write(pack(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Remove refused: " + str(error), file=sys.stderr)
        sys.exit(1)
