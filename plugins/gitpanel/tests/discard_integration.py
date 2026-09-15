#!/usr/bin/env python3
"""Production model + discard helper; all mutations confined to temp fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import runpy
import sys

HERE = Path(__file__).resolve().parent
LUA = shutil.which("luajit") or shutil.which("lua")
checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print("PASS", label)


with tempfile.TemporaryDirectory(prefix="lite-xl-discard-") as tmp:
    root = Path(tmp).resolve() / "repo"
    root.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Discard Test", GIT_AUTHOR_EMAIL="test@invalid",
               GIT_COMMITTER_NAME="Discard Test", GIT_COMMITTER_EMAIL="test@invalid")

    def git(*args, data=None):
        p = subprocess.run(["git", "--literal-pathspecs", "-C", str(root), *args], input=data,
                           capture_output=True, env=env, timeout=20)
        assert p.returncode == 0, p.stderr
        return p.stdout

    git("init", "-b", "main")
    path = ":(literal) [é]\nfile.txt"
    file = root / path
    file.write_bytes(b"HEAD\na\nb\nc\nd\ne\nf\nlast\n")
    git("add", "--", path)
    git("commit", "-m", "initial")

    def setup(original=b"INDEX\na\nb\nc\nd\ne\nf\nlast\n", modified=b"INDEX\nA\nb\nc\nd\nE\nf\nlast\n", mode=0o644):
        if file.is_symlink():
            file.unlink()
        file.write_bytes(original)
        file.chmod(mode)
        git("add", "--", path)
        file.write_bytes(modified)
        return original, modified, (root / ".git/index").read_bytes()

    def discard(block="", scenario="direct", y="M", on_capture=None, on_request=None, x="M"):
        calls = []
        with subprocess.Popen([LUA, str(HERE / "discard_bridge.lua"), str(root), path, y, str(block), scenario, x],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as p:
            def read():
                return p.stdout.read(int(p.stdout.readline()))

            def write(value):
                p.stdin.write(str(len(value)).encode() + b"\n" + value)

            while True:
                action = p.stdout.readline()
                assert action, p.stderr.read().decode()
                if action == b"RESULT\n":
                    result = dict(zip(("reloads", "dialogs", "stale"), (int(p.stdout.readline()) for _ in range(3))))
                    result["error"] = read().decode()
                    result["calls"] = calls
                    p.stdin.close()
                    assert p.wait(timeout=10) == 0, p.stderr.read().decode()
                    assert result["dialogs"] == 0, "actual discard path called NagView"
                    return result
                if action == b"CAPTURED\n":
                    if on_capture:
                        on_capture()
                    p.stdin.write(b"continue\n")
                    p.stdin.flush()
                    continue
                assert action == b"REQUEST\n", action
                args = [os.fsdecode(read()) for _ in range(int(p.stdout.readline()))]
                cwd, data = os.fsdecode(read()), read()
                assert cwd == str(root)
                assert (args[0] == "git" and "--literal-pathspecs" in args) or (args[:3] == ["python3", "-I", str(HERE.parent / "discard.py")] and args[4] == str(root))
                calls.append(args)
                if on_request:
                    on_request(args)
                proc = subprocess.run(args, cwd=cwd, input=data, capture_output=True, env=env, timeout=30)
                p.stdin.write(str(proc.returncode).encode() + b"\n")
                write(proc.stdout); write(proc.stderr); p.stdin.flush()

    for scenario in ("file-entry", "file-entry-duplicate"):
        original, modified, index = setup()
        result = discard(scenario=scenario)
        writes = [c for c in result["calls"] if c[0] == "python3" and c[3] == "replace"]
        check(len(writes) == 1 and result["reloads"] == 1 and result["stale"] == 1 and file.read_bytes() == original
              and (root / ".git/index").read_bytes() == index,
              "actual discard_file full-ready comparison restores exact index once without NagView: " + scenario)
    original, modified, index = setup()
    result = discard()
    assert not result["error"], result
    check(not result["error"] and result["reloads"] == 1 and result["stale"] == 1 and file.read_bytes() == original,
          "whole-file discard restores captured index, not HEAD, literal newline/UTF8/pathspec name")
    check((root / ".git/index").read_bytes() == index, "whole discard leaves index byte-for-byte unchanged")
    original, modified, index = setup()
    result = discard(1, "repeat")
    check(file.read_bytes() == modified.replace(b"A\n", b"a\n") and result["reloads"] == 1, "one block reverted, neighboring hunk retained")
    check((root / ".git/index").read_bytes() == index and result["dialogs"] == 0 and "Stale diff" in result["error"], "old hunk cannot act twice; index untouched")
    for original, modified, expected, label in [
        (b"a\nb\nc\nd\ne\n", b"a\nNEW\nb\nc\nd\nEDIT\n", b"a\nb\nc\nd\nEDIT\n", "added block"),
        (b"a\nb\nc\nd\ne\n", b"a\nc\nd\nEDIT\n", b"a\nb\nc\nd\nEDIT\n", "deleted block"),
        (b"a\nold", b"a\nnew", b"a\nold", "no final newline"),
        ("é\r\nold\r\n".encode(), "é\r\nβ\r\n".encode(), "é\r\nold\r\n".encode(), "CRLF/UTF8"),
        (b"", b"new\n", b"", "empty index file"),
        (b"a\n", b"", b"a\n", "empty disk file"),
    ]:
        _, _, index = setup(original, modified)
        r = discard(1)
        check(not r["error"] and file.read_bytes() == expected and (root / ".git/index").read_bytes() == index, label + " exact-byte hunk revert")
    original, modified, index = setup()
    file.unlink()
    r = discard(y="D")
    check(not r["error"] and file.read_bytes() == original and (root / ".git/index").read_bytes() == index, "deleted tracked file restored without index changes")
    setup(); file.unlink()
    r = discard(1, y="D")
    check(not r["error"] and file.read_bytes() == original, "deleted file block restore")
    for mode in (0o600, 0o644, 0o755):
        original, modified, _ = setup(mode=mode)
        r = discard(1)
        check(not r["error"] and file.stat().st_mode & 0o777 == mode, "preserve file permissions " + oct(mode))
    for block in ("", 1):
        original, modified, index = setup()
        r = discard(block, "dirty-initial")
        check(r["error"] and r["reloads"] == 0 and file.read_bytes() == modified and (root / ".git/index").read_bytes() == index,
              "Initial dirty buffer refuses direct file/block without disk/index changes " + str(block))
    for block in ("", 1):
        original, modified, index = setup()
        r = discard(block, "duplicate")
        writes = [c for c in r["calls"] if c[0] == "python3" and c[3] == "replace"]
        check(len(writes) == 1 and r["reloads"] == 1 and (root / ".git/index").read_bytes() == index,
              "duplicate direct file/block click writes once without NagView " + str(block))
    for scenario in ("dirty-preflight", "project-preflight", "root-preflight", "root-queued", "generation-queued"):
        original, modified, index = setup()
        r = discard(1, scenario)
        check((r["error"] or scenario == "project-preflight") and r["reloads"] == 0 and file.read_bytes() == modified and (root / ".git/index").read_bytes() == index,
              scenario + " rejects mutation after asynchronous preflight/scheduling")
    setup()
    r = discard(1, on_capture=lambda: file.write_bytes(b"external disk\n"))
    check(r["error"] and file.read_bytes() == b"external disk\n", "disk changed after capture refuses stale source")
    original, modified, index = setup()
    def change_index():
        file.write_bytes(b"external staged\n"); git("add", "--", path); file.write_bytes(modified)
    r = discard(1, on_capture=change_index)
    check(r["error"] and file.read_bytes() == modified and git("show", ":" + path) == b"external staged\n", "index changed after capture is preserved, not discarded")
    setup()
    def late_edit(args):
        if args[0] == "python3" and args[3] == "replace":
            file.write_bytes(b"last moment edit\n")
    r = discard(1, on_request=late_edit)
    check(r["error"] and r["stale"] and file.read_bytes() == b"last moment edit\n", "helper independently rechecks exact state immediately before replacement")
    setup()
    file.unlink(); file.symlink_to("target")
    (root / "target").write_bytes(b"target must survive\n")
    r = discard(1)
    check(r["error"] and file.is_symlink() and (root / "target").read_bytes() == b"target must survive\n", "worktree symlink target never overwritten")
    setup()
    os.link(file, root / "hardlink")
    r = discard(1)
    check("hardlink" in r["error"], "hardlinked file refused")
    (root / "hardlink").unlink()
    setup()
    file.chmod(0o755)
    r = discard(1)
    check("permission" in r["error"], "unstaged mode change refused")
    setup()
    (root / ".gitattributes").write_bytes(b"* filter=custom\n")
    r = discard(1)
    check("attributes/filters" in r["error"], "Git filters refuse destructive controls")
    (root / ".gitattributes").unlink()
    setup()
    git("config", "core.autocrlf", "true")
    r = discard(1)
    check("autocrlf" in r["error"], "autocrlf conversion explicitly unsupported for discard")
    git("config", "core.autocrlf", "false")
    original, modified, index = setup(modified=b"INDEX\na\nb\nc\nd\ne\nf\nlast\n")
    r = discard()
    check(r["error"] and r["dialogs"] == 0 and file.read_bytes() == original, "stale Changes row with already-clean disk refuses false discard success")
    setup(b"binary\0old", b"binary\0new")
    r = discard()
    check(r["error"] and r["dialogs"] == 0 and file.read_bytes() == b"binary\0new", "binary whole-file discard explicitly refused")
    setup()
    if sys.platform == "darwin":
        metadata = runpy.run_path(str(HERE.parent / "discard.py"))["plain_metadata"]
        with file.open("rb") as source:
            provenance = metadata(source.fileno())
        owner = (file.stat().st_uid, file.stat().st_gid)
        r = discard(1)
        with file.open("rb") as source:
            after = metadata(source.fileno())
        check(not r["error"] and after == provenance and (file.stat().st_uid, file.stat().st_gid) == owner,
              "macOS provenance bytes and ordinary ownership preserved exactly")
        setup()
        subprocess.run(["/usr/bin/xattr", "-w", "gitpanel.test", "keep", str(file)], check=True)
        r = discard(1)
        check("Extended attributes" in r["error"] and subprocess.check_output(["/usr/bin/xattr", "-p", "gitpanel.test", str(file)]).strip() == b"keep", "unsupported xattrs preserved by refusal, never removed")
        subprocess.run(["/usr/bin/xattr", "-d", "gitpanel.test", str(file)], check=True)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(file)], check=True)
        r = discard(1)
        check("ACL" in r["error"], "ACL-bearing file safely refused")
        subprocess.run(["/bin/chmod", "-N", str(file)], check=True)
    setup()
    git("rm", "--cached", "-f", "--", path)
    r = discard()
    check(r["error"] and r["dialogs"] == 0, "untracked files never deleted")
    check(not list(root.glob(".gitpanel-discard-*")), "all temporary replacement files cleaned up")
    setup()
    env["PYTHONOPTIMIZE"] = "1"
    r = discard(1)
    check(not r["error"] and r["reloads"] == 1, "isolated interpreter ignores PYTHONOPTIMIZE and keeps safety assertions enabled")
    env.pop("PYTHONOPTIMIZE")
    before = file.read_bytes()
    refused = subprocess.run([sys.executable, "-O", str(HERE.parent / "discard.py"), "replace", str(root), path], input=b"", capture_output=True, env=env)
    check(refused.returncode != 0 and b"Optimized Python" in refused.stderr and file.read_bytes() == before, "direct optimized helper invocation safely refused")
    path = "nested/file.txt"
    (root / "nested").mkdir()
    file = root / path
    original, modified, index = setup()
    def replace_parent():
        (root / "nested").rename(root / "moved")
        (root / "nested").symlink_to("moved", target_is_directory=True)
    r = discard(1, on_capture=replace_parent)
    check(r["error"] and (root / "moved/file.txt").read_bytes() == modified, "symlink ancestor introduced during dialog cannot redirect replacement")

print(f"{checks} production-discard real-Git checks passed; temporary repositories removed.")
