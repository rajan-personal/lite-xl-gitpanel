#!/usr/bin/env python3
"""R04B native hit/command -> real helper, only in a NEW owned Git fixture."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="gitpanel-remove-ui-") as tmp:
    root = Path(tmp).resolve() / "repo"
    root.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Remove fixture", GIT_AUTHOR_EMAIL="test@invalid",
               GIT_COMMITTER_NAME="Remove fixture", GIT_COMMITTER_EMAIL="test@invalid")
    def git(*args):
        return subprocess.check_output(["git", "--no-optional-locks", "--literal-pathspecs",
                                        "-c", "diff.autoRefreshIndex=false", "-C", str(root), *args], env=env)
    git("init", "-b", "main")
    (root / "neighbor").write_bytes(b"neighbor HEAD\n")
    git("add", ".")
    git("commit", "-m", "owned fixture only")
    head = git("rev-parse", "HEAD")
    source = root / "new"
    # Measure lookup equivalence on this owned volume, never infer it from Git.
    aliases = {}
    for kind, original, alternate in (("case", "new", "NEW"), ("unicode", "néw", "ne\u0301w")):
        probe = Path(tmp) / (kind + "-lookup")
        probe.mkdir()
        (probe / alternate).write_bytes(b"alias probe\n")
        aliases[kind] = (probe / original).exists() and (probe / original).stat().st_ino == (probe / alternate).stat().st_ino
        print("MEASURED %s lookup alias=%s platform=%s" % (kind, aliases[kind], os.uname().sysname), flush=True)
        if not aliases[kind]:
            print("SKIP R04B %s final-boundary alias: volume lookup is distinct" % kind, flush=True)
    # Exercise native Lua -> libc rename, not a bridge returning invented errno.
    # Snapshot metadata AFTER initial content reads and BEFORE later reads: atime
    # changes from verification must not hide any effect of the no-op itself.
    probe = Path(tmp) / "native-noop"
    probe.mkdir()
    (probe / "regular").write_bytes(b"source bytes\n")
    (probe / "neighbor").write_bytes(b"neighbor bytes\n")
    (probe / "directory").mkdir()
    (probe / "dangling").symlink_to("missing-target")
    os.mkfifo(probe / "fifo")
    (probe / "NEW").write_bytes(b"case bytes\n")
    (probe / "ne\u0301w").write_bytes(b"unicode bytes\n")
    (probe / "LINK").symlink_to("missing-target")
    def metadata():
        paths = [probe] + sorted(probe.iterdir())
        return {os.fsencode(p.name): tuple(getattr(p.lstat(), field) for field in
                ("st_dev", "st_ino", "st_mode", "st_nlink", "st_uid", "st_gid", "st_size",
                 "st_atime_ns", "st_mtime_ns", "st_ctime_ns")) for p in paths}
    def contents():
        return {p.name: p.read_bytes() for p in probe.iterdir() if not p.is_symlink() and stat.S_ISREG(p.lstat().st_mode)}
    cases = [(name, True, None) for name in ("regular", "directory", "dangling", "fifo")]
    cases += [("absent", False, 2), ("regular/child", False, 20)]
    if aliases["case"]:
        cases += [("new", True, None), ("link", True, None)]
    if aliases["unicode"]:
        cases += [("néw", True, None)]
    for name, success, code in cases:
        before_contents = contents()
        before = metadata()
        result = subprocess.run([shutil.which("luajit"), "-e",
            'local p=assert(io.read("*l")); assert(p~=""); local ok,msg,n=os.rename(p,p); '
            'io.write(tostring(ok)," ",tostring(n))'], input=os.fsencode(probe / name) + b"\n",
            capture_output=True, timeout=5, env=env)
        after = metadata()
        assert result.returncode == 0, result.stderr
        assert result.stdout == (b"true nil" if success else ("nil %d" % code).encode()), result.stdout
        assert before == after and before_contents == contents(), name
        print("PASS R04B native same-path probe %s result=%s preserves names/inodes/modes/timestamps/content/neighbor" %
              (name, result.stdout.decode()), flush=True)
    with subprocess.Popen([shutil.which("luajit"), str(HERE / "remove_ui_native.lua"), str(root),
                           "yes" if aliases["case"] else "no", "yes" if aliases["unicode"] else "no"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env) as p:
        def read():
            return p.stdout.read(int(p.stdout.readline()))
        def write(value):
            p.stdin.write(str(len(value)).encode() + b"\n" + value)
        receipt = None
        while True:
            line = p.stdout.readline()
            if not line:
                break
            if line == b"SETUP\n":
                mode = p.stdout.readline().strip()
                lock = root / ".git/index.lock"
                if lock.exists():
                    lock.unlink()
                if git("ls-files", "--", source.name):
                    git("rm", "--cached", "--", source.name)
                if source.exists() or source.is_symlink():
                    source.unlink()
                source = root / ("néw" if mode == b"unicode" else "new")
                content = b"first\nsecond\nlast\n" if mode != b"empty" else b""
                if mode == b"binary":
                    content = b"binary\0content\xff"
                source.write_bytes(content)
                source.chmod(0o751)
                (root / "neighbor").write_bytes(b"neighbor staged\n")
                git("add", "--", "neighbor")
                (root / "neighbor").write_bytes(b"neighbor working\n")
                if mode == b"staged":
                    git("add", "--", source.name)
                index = (root / ".git/index").read_bytes()
                receipt = None
                p.stdin.write(b"continue\n"); p.stdin.flush()
            elif line == b"STAT\n":
                path = Path(os.fsdecode(read()))
                assert path == source
                # Native get_file_info uses stat (follows links), with nil plus
                # an error string for ENOENT as well as inspection failures.
                try:
                    info = path.stat()
                    p.stdin.write(b"yes\n")
                    write(b"dir" if stat.S_ISDIR(info.st_mode) else b"file")
                except OSError as error:
                    p.stdin.write(b"error\n"); write(os.fsencode(str(error)))
                p.stdin.flush()
            elif line == b"LIST_DIR\n":
                path = Path(os.fsdecode(read()))
                assert path == root
                try:
                    names = os.listdir(os.fsencode(path))
                    p.stdin.write(b"yes\n" + str(len(names)).encode() + b"\n")
                    for name in names:
                        write(name)
                except OSError as error:
                    p.stdin.write(b"error\n"); write(os.fsencode(str(error)))
                p.stdin.flush()
            elif line == b"EVENT\n":
                event = p.stdout.readline().strip()
                if event == b"source":
                    source.write_bytes(b"newer external source\n")
                elif event == b"stage":
                    if not source.exists():
                        source.write_bytes(b"newer staged source\n")
                    git("add", "--", source.name)
                    index = (root / ".git/index").read_bytes()
                elif event == b"lock":
                    (root / ".git/index.lock").write_bytes(b"external lock\n")
                elif event == b"accessible":
                    root.chmod(0o700)
                elif event == b"fifo":
                    assert receipt is not None and not os.path.lexists(source)
                    os.mkfifo(source)
                elif event in (b"case-alias", b"unicode-alias", b"alias-dangling"):
                    assert receipt is not None and not os.path.lexists(source)
                    alternate = root / ("ne\u0301w" if event == b"unicode-alias" else "NEW")
                    if event == b"alias-dangling":
                        alternate.symlink_to("absent-link-target")
                    else:
                        alternate.write_bytes(b"newer external source\n")
                    assert source.lstat().st_ino == alternate.lstat().st_ino
                    assert os.fsencode(source.name) not in os.listdir(os.fsencode(root))
                    print("MEASURED final boundary %s raw-name absent, lookup inode=%s" % (event.decode(), source.lstat().st_ino), flush=True)
                elif event in (b"inaccessible", b"unsearchable", b"unlistable", b"dangling"):
                    assert receipt is not None and not source.exists()
                    if event == b"dangling":
                        source.symlink_to("absent-link-target")
                    else:
                        source.write_bytes(b"newer external source\n")
                        root.chmod({b"inaccessible": 0, b"unsearchable": 0o400,
                                    b"unlistable": 0o100}[event])
                    try:
                        source.stat()
                    except OSError as error:
                        assert event != b"unlistable"
                        assert isinstance(error, FileNotFoundError if event == b"dangling" else PermissionError)
                    else:
                        assert event == b"unlistable", "fixture must produce a real native inspection error"
                    try:
                        names = os.listdir(os.fsencode(root))
                    except PermissionError:
                        assert event in (b"inaccessible", b"unlistable")
                    else:
                        assert event in (b"unsearchable", b"dangling") and b"new" in names
                else:
                    raise AssertionError(event)
                p.stdin.write(b"continue\n"); p.stdin.flush()
            elif line == b"REQUEST\n":
                args = [os.fsdecode(read()) for _ in range(int(p.stdout.readline()))]
                cwd, data = os.fsdecode(read()), read()
                assert cwd == str(root)
                assert (args[0] == "git" and "--literal-pathspecs" in args and "--no-optional-locks" in args) or (
                    args[:2] == ["python3", "-I"] and args[2] in
                    [str(HERE.parent / name) for name in ("remove.py", "staging.py")]
                    and args[4] == str(root))
                result = subprocess.run(args, cwd=cwd, input=data, capture_output=True, env=env, timeout=40)
                if args[0] == "python3" and args[3] == "remove" and result.returncode == 0:
                    fields, remaining = [], result.stdout
                    for _ in range(3):
                        n, remaining = remaining.split(b"\n", 1)
                        fields.append(remaining[:int(n)]); remaining = remaining[int(n):]
                    assert not remaining and fields[1:] == [os.fsencode(source.name), b"removed"]
                    receipt = Path(os.fsdecode(fields[0]))
                    assert receipt.parent == root / ".git/gitpanel-recovery"
                    metadata = json.loads((receipt / "metadata.json").read_bytes())
                    assert metadata["path"] == source.name and metadata["mode"] == 0o751
                    for name in ("content", "snapshot"):
                        backup = receipt / name
                        assert backup.read_bytes() == content
                        assert stat.S_IMODE(backup.stat().st_mode) == 0o751
                    assert not source.exists()
                    assert (root / ".git/index").read_bytes() == index
                p.stdin.write(str(result.returncode).encode() + b"\n")
                write(result.stdout); write(result.stderr); p.stdin.flush()
            elif line == b"VERIFY\n":
                expected = p.stdout.readline().strip()
                root.chmod(0o700)
                assert source.exists() == (expected not in (b"removed", b"dangling")), expected
                if expected == b"fifo":
                    assert stat.S_ISFIFO(source.lstat().st_mode)
                if expected == b"dangling":
                    assert source.is_symlink() and os.readlink(source) == "absent-link-target"
                if expected == b"original":
                    assert source.read_bytes() == content
                elif expected == b"newer":
                    assert source.read_bytes() in (b"newer external source\n", b"newer staged source\n")
                if expected == b"removed":
                    assert receipt is not None
                assert (root / ".git/index").read_bytes() == index
                assert git("rev-parse", "HEAD") == head
                assert git("show", ":neighbor") == b"neighbor staged\n"
                assert (root / "neighbor").read_bytes() == b"neighbor working\n"
                p.stdin.write(b"continue\n"); p.stdin.flush()
            else:
                print(line.decode(), end="", flush=True)
        assert p.wait(timeout=10) == 0
print("R04B real Git receipt/backup mode/content/index/HEAD/neighbor assertions passed (included in native checks)")
