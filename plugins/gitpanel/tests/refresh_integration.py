#!/usr/bin/env python3
"""R02/R03 actual Model -> Python helper -> native Node/Doc, in an owned Git fixture."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="gitpanel-refresh-") as tmp:
    root = Path(tmp).resolve() / "repo"
    root.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Refresh fixture", GIT_AUTHOR_EMAIL="test@invalid",
               GIT_COMMITTER_NAME="Refresh fixture", GIT_COMMITTER_EMAIL="test@invalid")
    def git(*args):
        return subprocess.check_output(["git", "--literal-pathspecs", "-C", str(root), *args], env=env)
    git("init", "-b", "main")
    (root / "file").write_bytes(b"HEAD\na\nb\nc\nd\ne\nf\nlast\n")
    (root / "neighbor").write_bytes(b"neighbor HEAD\n")
    git("add", ".")
    git("commit", "-m", "fixture only")
    head = git("rev-parse", "HEAD")
    with subprocess.Popen([shutil.which("luajit"), str(HERE / "refresh_native.lua"), str(root)],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env) as p:
        def read():
            return p.stdout.read(int(p.stdout.readline()))
        def write(value):
            p.stdin.write(str(len(value)).encode() + b"\n" + value)
        index = None
        while True:
            line = p.stdout.readline()
            if not line:
                break
            if line == b"SETUP\n":
                mode = p.stdout.readline().strip()
                (root / "file").write_bytes(b"INDEX\na\nb\nc\nd\ne\nf\nlast\n")
                (root / "neighbor").write_bytes(b"neighbor staged\n")
                git("add", ".")
                (root / "neighbor").write_bytes(b"neighbor working\n")
                (root / "file").write_bytes(b"INDEX\nA\nb\nc\nd\nE\nf\nlast\n")
                if mode == b"insertions":
                    (root / "file").write_bytes(b"INDEX\na\nadded first\nb\nc\nd\ne\nf\nadded last\nlast\n")
                elif mode == b"mixed-addition":
                    (root / "file").write_bytes(b"INDEX\nA\nb\nc\nd\ne\nf\nadded last\nlast\n")
                elif mode == b"deleted":
                    (root / "file").unlink()
                index = (root / ".git/index").read_bytes()
                p.stdin.write(b"continue\n"); p.stdin.flush()
            elif line == b"REQUEST\n":
                args = [os.fsdecode(read()) for _ in range(int(p.stdout.readline()))]
                cwd, data = os.fsdecode(read()), read()
                assert cwd == str(root), (args, cwd)
                assert (args[0] == "git" and "--literal-pathspecs" in args) or (
                    args[:2] == ["python3", "-I"] and args[2] in
                    [str(HERE.parent / name) for name in ("discard.py", "staging.py")]
                    and args[4] == str(root))
                result = subprocess.run(args, cwd=cwd, input=data, capture_output=True, env=env, timeout=30)
                p.stdin.write(str(result.returncode).encode() + b"\n")
                write(result.stdout); write(result.stderr); p.stdin.flush()
            elif line == b"VERIFY_CLEAN\n":
                assert git("-c", "diff.autoRefreshIndex=false", "diff", "--no-ext-diff", "--", "file") == b""
                assert (root / "file").is_file(), "reverting added lines retains the tracked file"
                assert (root / "file").read_bytes() == git("show", ":file")
                result = subprocess.run(["python3", "-I", str(HERE.parent / "staging.py"),
                                         "snapshot", str(root), "file", "changes"],
                                        capture_output=True, env=env, timeout=30)
                assert result.returncode != 0 and b"No textual changes remain" in result.stderr, result
                assert (root / ".git/index").read_bytes() == index
                p.stdin.write(b"continue\n"); p.stdin.flush()
            elif line == b"VERIFY\n":
                expected = read()
                assert (root / "file").read_bytes() == expected, "exact working bytes"
                assert (root / ".git/index").read_bytes() == index, "byte-identical staged index"
                assert git("rev-parse", "HEAD") == head, "HEAD unchanged"
                assert git("show", ":neighbor") == b"neighbor staged\n", "neighbor index unchanged"
                assert (root / "neighbor").read_bytes() == b"neighbor working\n", "neighbor disk unchanged"
                p.stdin.write(b"continue\n"); p.stdin.flush()
            else:
                print(line.decode(), end="", flush=True)
        assert p.wait(timeout=10) == 0
print("R02/R03 real Git fixture byte/index/HEAD/neighbor assertions passed (included in native scenario checks)")
