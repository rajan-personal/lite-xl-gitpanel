#!/usr/bin/env python3
"""Disposable real Git integration; no shell, network or user repository access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import runpy
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
LUA = shutil.which("luajit") or shutil.which("lua")
assert LUA, "Lua or LuaJIT is required"
checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print("PASS", label)


def bridge(action, *args, data=b""):
    result = subprocess.run([LUA, str(HERE / "protocol_bridge.lua"), action, *args],
                            input=data, capture_output=True, check=True)
    return result.stdout[:-1].decode().split("\0")


with tempfile.TemporaryDirectory(prefix="lite-xl-gitpanel-") as tmp:
    home = Path(tmp) / "home"
    home.mkdir()
    root = Path(tmp) / "repo with spaces"
    root.mkdir()
    env = os.environ.copy()
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home), GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0", LC_ALL="C",
               GIT_AUTHOR_NAME="Gitpanel Test", GIT_AUTHOR_EMAIL="test@invalid",
               GIT_COMMITTER_NAME="Gitpanel Test", GIT_COMMITTER_EMAIL="test@invalid")
    # Do not inherit repository redirection, injected config or signing settings.
    for key in list(env):
        if key in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"} or key.startswith("GIT_CONFIG_KEY_") or key.startswith("GIT_CONFIG_VALUE_") or key == "GIT_CONFIG_COUNT":
            del env[key]

    # Exercise ordinary status/stage/commit/switch with inherited overrides too.
    env.update(GIT_DIR=str(home / "missing.git"), GIT_WORK_TREE=str(home),
               GIT_INDEX_FILE=str(home / "wrong-index"), GIT_CONFIG_COUNT="1",
               GIT_CONFIG_KEY_0="core.bare", GIT_CONFIG_VALUE_0="true",
               GIT_OBJECT_DIRECTORY=str(home / "missing-objects"), GIT_LITERAL_PATHSPECS="unsafe")
    policy = runpy.run_path(str(HERE.parent / "git_env.py"))["git_environment"]
    with patch.dict(os.environ, dict(env, GIT_ASKPASS="/auth path/askpass", SSH_AUTH_SOCK="/agent/socket",
                                    GIT_UNKNOWN_FUTURE_OVERRIDE="unsafe"), clear=True):
        cleaned = policy()
        check(not any(key in cleaned for key in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_UNKNOWN_FUTURE_OVERRIDE")),
              "shared policy drops redirects, config injection and unknown Git settings")
        check(cleaned["GIT_ASKPASS"] == "/auth path/askpass" and cleaned["SSH_AUTH_SOCK"] == "/agent/socket"
              and cleaned["PATH"] == env["PATH"] and cleaned["GIT_AUTHOR_NAME"] == env["GIT_AUTHOR_NAME"]
              and cleaned["GIT_CONFIG_GLOBAL"] == os.devnull,
              "ordinary Git preserves authentication, executable path, identity and user config policy")
        check("GIT_ASKPASS" not in policy(local_only=True), "local mutation helpers omit askpass")

    def run(*args, data=None, expected=(0,), cwd=root):
        p = subprocess.run([sys.executable, "-I", str(HERE.parent / "git_env.py"), "--no-pager", "--literal-pathspecs", "--no-optional-locks", "-C", str(cwd), *args],
                           input=data, capture_output=True, env=env)
        assert p.returncode in expected, (args, p.returncode, p.stderr)
        return p

    def status():
        values = bridge("status", data=run("status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all").stdout)
        entries = [values[i:i+5] for i in range(4, len(values), 5)]
        return values[:4], {g: [r for r in entries if r[0] == g] for g in ("staged", "changes", "untracked", "conflicts")}

    def stage(group, names, unborn=False):
        args = bridge("stage", group, str(unborn).lower())
        return run(*args, data=b"".join(os.fsencode(p) + b"\0" for p in names))

    def diff(group, name, old="", y=" "):
        return run(*bridge("diff", group, name, old, y), expected=(0, 1) if group == "untracked" else (0,)).stdout

    run("init", "-b", "main")
    names = ["partial.txt", "space name.txt", "line\nbreak.txt", ":(glob)*.txt", "[abc].txt", "-option.txt", "unicodé.txt"]
    for name in names:
        (root / name).write_text("base\n")
    meta, groups = status()
    check(meta[:3] == ["main", "true", "false"] and len(groups["untracked"]) == len(names), "unborn branch and NUL paths")
    check(b"+base" in diff("untracked", "line\nbreak.txt"), "untracked diff handles newline path")
    check(b"+base" in diff("untracked", ":(glob)*.txt"), "untracked pathspec metacharacter diff")
    stage("untracked", names)
    (root / "partial.txt").write_text("worktree\n")
    meta, groups = status()
    check(any(e[1] == "partial.txt" for e in groups["staged"]) and any(e[1] == "partial.txt" for e in groups["changes"]), "partially staged appears independently in both groups")
    check(b"+base" in diff("staged", "partial.txt") and b"worktree" not in diff("staged", "partial.txt"), "unborn staged diff reads index only")
    stage("staged", ["partial.txt"], True)
    check((root / "partial.txt").read_text() == "worktree\n", "unborn unstage preserves divergent worktree")
    stage("untracked", ["partial.txt"])
    initial_message = b"#123 Initial fixture\n\nMultiline description\n# Keep this issue reference\n## Markdown heading\n"
    run("commit", "--cleanup=whitespace", "--file=-", data=initial_message)
    check(b"Multiline description" in run("log", "-1", "--format=%B").stdout, "multiline commit message via stdin")
    check(run("log", "-1", "--format=%B").stdout.rstrip(b"\n") == initial_message.rstrip(b"\n"), "comment-prefixed subject, issue reference and Markdown body survive commit")

    (root / "partial.txt").write_text("indexed\n")
    stage("changes", ["partial.txt"])
    (root / "partial.txt").write_text("not committed\n")
    check(b"+indexed" in diff("staged", "partial.txt") and b"not committed" not in diff("staged", "partial.txt"), "staged diff remains distinct from worktree after HEAD exists")
    check(b"-indexed" in diff("changes", "partial.txt") and b"+not committed" in diff("changes", "partial.txt"), "unstaged diff compares index to disk")
    run("commit", "--cleanup=whitespace", "--file=-", data=b"Only index\n")
    check(run("show", "HEAD:partial.txt").stdout == b"indexed\n" and (root / "partial.txt").read_text() == "not committed\n", "commit commits only the index")
    stage("changes", ["partial.txt"])
    stage("staged", ["partial.txt"])
    check(not status()[1]["staged"] and (root / "partial.txt").read_text() == "not committed\n", "HEAD unstage preserves disk contents")

    (root / ":(glob)*.txt").write_text("literal edit\n")
    (root / "space name.txt").write_text("other edit\n")
    stage("changes", [":(glob)*.txt"])
    check([e[1] for e in status()[1]["staged"]] == [":(glob)*.txt"], "literal staging never expands magic pathspec")
    stage("staged", [":(glob)*.txt"])
    run("mv", "--", "line\nbreak.txt", "renamed\nfile.txt")
    staged = status()[1]["staged"]
    rename = next(e for e in staged if e[1] == "renamed\nfile.txt")
    check(rename[2] == "R" and rename[4] == "line\nbreak.txt", "rename record consumes reversed NUL path pair")
    check(b"rename from" in diff("staged", rename[1], rename[4]), "staged rename diff includes both names")
    stage("staged", [rename[1], rename[4]])
    check(not status()[1]["staged"] and (root / rename[1]).exists(), "unstage rename restores both index paths only")
    (root / "[abc].txt").unlink()
    check(b"deleted file" in diff("changes", "[abc].txt"), "deleted literal path unstaged diff")
    stage("changes", ["[abc].txt"])
    check(b"deleted file" in diff("staged", "[abc].txt"), "staged deletion diff")

    # All cleanup commands operate solely on this disposable fixture.
    run("reset", "--hard", "HEAD")
    run("clean", "-fd")
    run("branch", "feature")
    run("update-ref", "refs/remotes/origin/feature", "HEAD")
    run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/feature")
    branches = bridge("branches", data=run("for-each-ref", "--sort=refname", "--format=%(refname)%00%(symref)%00", "refs/heads/", "refs/remotes/").stdout)
    check("origin/feature" in branches and "origin/HEAD" not in branches and "feature" in branches, "local/remote branch parsing excludes symbolic remote HEAD")
    run("switch", "--no-guess", "feature")
    check(status()[0][0] == "feature", "local branch switch")
    run("switch", "--no-guess", "-c", "created")
    check(status()[0][0] == "created", "create local branch")
    run("switch", "--detach", "HEAD")
    check(status()[0][2] == "true", "detached HEAD status")
    run("switch", "main")

    (root / "partial.txt").write_text("main branch\n")
    stage("changes", ["partial.txt"])
    run("commit", "-m", "main edit")
    run("switch", "feature")
    (root / "partial.txt").write_text("feature branch\n")
    stage("changes", ["partial.txt"])
    run("commit", "-m", "feature edit")
    run("merge", "main", expected=(1,))
    check(len(status()[1]["conflicts"]) == 1 and not status()[1]["staged"], "merge conflict isolated from staged and changes")
    check(b"diff --cc" in diff("conflicts", "partial.txt"), "conflict opens combined diff")
    run("merge", "--abort")
    (root / "partial.txt").write_text("hook fixture\n")
    stage("changes", ["partial.txt"])
    hook = root / ".git/hooks/pre-commit"
    hook.write_text("#!/bin/sh\nprintf 'intentional hook failure\\n' >&2\nexit 1\n")
    hook.chmod(0o700)
    failed = run("commit", "--cleanup=whitespace", "--file=-", data=b"Preserve this draft\n", expected=(1,))
    check(b"intentional hook failure" in failed.stderr and len(status()[1]["staged"]) == 1, "commit failure exposes stderr and preserves index")
    sub = root / "nested"
    sub.mkdir()
    check(run("rev-parse", "--show-toplevel", cwd=sub).stdout.rstrip(b"\n") == os.fsencode(root.resolve()), "nested project resolves repository root")

print(f"{checks} real-Git checks passed; temporary repositories removed.")
