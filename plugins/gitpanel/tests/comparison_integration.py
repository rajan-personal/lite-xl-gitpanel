#!/usr/bin/env python3
"""Production comparison pipeline, real Git, disposable repositories only."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
LUA = shutil.which("luajit") or shutil.which("lua")
checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print("PASS", label)


with tempfile.TemporaryDirectory(prefix="lite-xl-comparison-") as tmp:
    root = Path(tmp) / "repo"
    root.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0", LC_ALL="C",
               GIT_AUTHOR_NAME="Diff Test", GIT_AUTHOR_EMAIL="test@invalid",
               GIT_COMMITTER_NAME="Diff Test", GIT_COMMITTER_EMAIL="test@invalid")

    def git(*args, data=None, expected=(0,)):
        p = subprocess.run(["git", "--no-pager", "--literal-pathspecs", "-C", str(root), *args],
                           input=data, capture_output=True, env=env, timeout=20)
        assert p.returncode in expected, (args, p.stderr)
        return p.stdout

    def compare(group, path, x=" ", y="M", old=""):
        with subprocess.Popen([LUA, str(HERE / "comparison_bridge.lua"), str(root), group, path, x, y, old],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as p:
            def read():
                size = int(p.stdout.readline())
                return p.stdout.read(size)

            def write(data):
                p.stdin.write(str(len(data)).encode() + b"\n" + data)

            while True:
                action = p.stdout.readline()
                assert action, p.stderr.read().decode()
                if action == b"RESULT\n":
                    result = dict(zip(("original", "modified", "patch", "unsupported"), (read() for _ in range(4))))
                    result["counts"] = (int(p.stdout.readline()), int(p.stdout.readline()))
                    result["rows"] = [tuple(map(int, p.stdout.readline().split(b","))) for _ in range(int(p.stdout.readline()))]
                    p.stdin.close()
                    assert p.wait(timeout=10) == 0, p.stderr.read().decode()
                    return result
                assert action == b"REQUEST\n", action
                args = [os.fsdecode(read()) for _ in range(int(p.stdout.readline()))]
                cwd = os.fsdecode(read())
                assert cwd == str(root)
                assert (args[0] == "git" and "--literal-pathspecs" in args) or (args[:4] == ["python3", "-I", str(HERE.parent / "discard.py"), "snapshot"] and args[4] == str(root))
                proc = subprocess.run(args, cwd=cwd, capture_output=True, env=env, timeout=20)
                p.stdin.write(str(proc.returncode).encode() + b"\n")
                write(proc.stdout)
                write(proc.stderr)
                p.stdin.flush()

    def exact(result, original, modified):
        assert not result["unsupported"], result["unsupported"].decode()
        return result["original"] == original and result["modified"] == modified

    git("init", "-b", "main")
    path = "unicodé\n[lit].lua"
    (root / path).write_bytes(b"head\n\nlast")
    check(exact(compare("untracked", path, "?", "?"), b"", b"head\n\nlast"), "untracked literal UTF-8/newline path empty -> exact disk")
    git("add", "--", path)
    (root / path).write_bytes(b"disk only\n")
    check(exact(compare("staged", path, "A"), b"", b"head\n\nlast"), "unborn staged uses empty HEAD -> index, not disk")
    git("commit", "-m", "Initial")
    (root / path).write_bytes(b"index\n\nlast\n")
    git("add", "--", path)
    (root / path).write_bytes("disk β\r\n\r\nlast\r\n".encode())
    d = compare("staged", path, "M")
    check(exact(d, b"head\n\nlast", b"index\n\nlast\n") and d["counts"] == (3, 3), "staged HEAD/index no-newline and blank-line counts")
    check(exact(compare("changes", path), b"index\n\nlast\n", "disk β\r\n\r\nlast\r\n".encode()), "tracked Changes uses index -> exact CRLF UTF-8 disk")
    (root / "empty.txt").write_bytes(b"")
    d = compare("untracked", "empty.txt", "?", "?")
    check(exact(d, b"", b"") and d["counts"] == (0, 0) and not d["rows"], "empty untracked file has zero lines, not blank success")
    git("add", "--", "empty.txt")
    check(exact(compare("staged", "empty.txt", "A"), b"", b""), "staged empty new file")
    git("commit", "-m", "Index state")
    (root / path).write_bytes(b"index\n\nlast\n")
    renamed = "renamed\nfile.lua"
    git("mv", "--", path, renamed)
    d = compare("staged", renamed, "R", " ", path)
    check(exact(d, b"index\n\nlast\n", b"index\n\nlast\n") and len(d["rows"]) == 3, "metadata-only staged rename preserves full original and modified contents")
    (root / renamed).write_bytes(b"index\n\nchanged last\n")
    check(exact(compare("changes", renamed, "R", "M", path), b"index\n\nlast\n", b"index\n\nchanged last\n"), "renamed tracked Changes reads new index path, not old HEAD path")
    git("add", "--", renamed)
    d = compare("staged", renamed, "R", " ", path)
    check(exact(d, b"index\n\nlast\n", b"index\n\nchanged last\n"), "edited staged rename validates old/new sources")
    git("commit", "-m", "Rename")
    (root / renamed).unlink()
    d = compare("changes", renamed, " ", "D")
    check(exact(d, b"index\n\nchanged last\n", b"") and all(row[1] == 0 for row in d["rows"]), "tracked deletion has only real original numbers and modified gaps")
    git("add", "-A")
    check(exact(compare("staged", renamed, "D", " "), b"index\n\nchanged last\n", b""), "staged deletion HEAD -> empty index")
    (root / "binary.dat").write_bytes(b"a\0b\xff")
    d = compare("untracked", "binary.dat", "?", "?")
    check(b"Binary" in d["unsupported"] and b"Binary files" in d["patch"], "untracked binary explicitly falls back to raw Git representation")
    git("add", "binary.dat")
    check(b"Binary" in compare("staged", "binary.dat", "A")["unsupported"], "staged binary explicitly unsupported")
    (root / ".gitattributes").write_bytes(b"opaque.txt binary\n")
    (root / "opaque.txt").write_bytes(b"not NUL but marked binary\n")
    git("add", ".gitattributes", "opaque.txt")
    check(b"Binary" in compare("staged", "opaque.txt", "A")["unsupported"], "attribute-marked binary is not faked as text")
    git("commit", "-m", "Binary/deletion")
    head = git("rev-parse", "HEAD").strip()
    git("update-index", "--add", "--cacheinfo", "160000," + head.decode() + ",sub")
    check(b"Submodule" in compare("staged", "sub", "A")["unsupported"], "gitlink/submodule explicitly unsupported")
    git("update-index", "--force-remove", "sub")
    (root / "link").symlink_to("empty.txt")
    git("add", "link")
    check(b"Symbolic link" in compare("staged", "link", "A")["unsupported"], "symlink uses explicit fallback rather than following target")
    (root / "crlf.txt").write_bytes(b"base\nunchanged\n")
    git("add", "crlf.txt")
    git("commit", "-m", "CRLF base")
    git("config", "core.autocrlf", "true")
    (root / "crlf.txt").write_bytes(b"edited\r\nunchanged\r\n")
    check(exact(compare("changes", "crlf.txt"), b"base\nunchanged\n", b"edited\r\nunchanged\r\n"), "autocrlf hunk normalization retains exact raw disk CRLF source")
    git("config", "core.autocrlf", "false")
    (root / "large.txt").write_bytes(b"row\n" * 50000)
    started = time.monotonic()
    d = compare("untracked", "large.txt", "?", "?")
    check(exact(d, b"", b"row\n" * 50000) and d["counts"] == (0, 50000) and len(d["rows"]) == 50000 and time.monotonic() - started < 10, "50,000-line real Git comparison complete within bounded time")
    (root / "large.txt").write_bytes(b"row\n" * 50001)
    check(b"50,000" in compare("untracked", "large.txt", "?", "?")["unsupported"], "over-limit line count rejected visibly, not truncated")
    (root / "long.txt").write_bytes(b"x" * 16385)
    check(b"16 KiB" in compare("untracked", "long.txt", "?", "?")["unsupported"], "long line rejected before native tokenization")
    (root / "bytes.txt").write_bytes(b"x\n" * (1024 * 1024 + 1))
    check(b"2 MiB" in compare("untracked", "bytes.txt", "?", "?")["unsupported"], "large disk source cap rejects rather than silently truncating")
    # Construct real unmerged index stages without checkout, merge hooks or network.
    blob1 = git("hash-object", "-w", "--stdin", data=b"base\n").strip()
    blob2 = git("hash-object", "-w", "--stdin", data=b"ours\n").strip()
    blob3 = git("hash-object", "-w", "--stdin", data=b"theirs\n").strip()
    git("update-index", "--index-info", data=b"".join(b"100644 " + blob + b" " + str(i).encode() + b"\tconflict.txt\n" for i, blob in enumerate((blob1, blob2, blob3), 1)))
    (root / "conflict.txt").write_bytes(b"<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n")
    d = compare("conflicts", "conflict.txt", "U", "U")
    check(b"Unmerged/conflict" in d["unsupported"] and b"diff --cc" in d["patch"], "real combined merge diff uses explicit honest raw fallback")

print(f"{checks} production-comparison real-Git checks passed; temporary repositories removed.")
