#!/usr/bin/env python3
"""Shared Git environment policy and shell-free exec wrapper for panel commands."""
import os
import sys


_ALLOWED = frozenset({
    "GIT_TERMINAL_PROMPT", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ASKPASS",
    "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
})


def git_environment(local_only=False):
    # A -C argument does not override GIT_DIR, GIT_WORK_TREE or GIT_INDEX_FILE.
    # Filter the entire namespace, including injected config and object paths,
    # while retaining authentication/identity and explicit user config policy.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_") or key in _ALLOWED}
    if local_only:
        env.pop("GIT_ASKPASS", None)
    env.update(GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never", LC_ALL="C")
    return env


if __name__ == "__main__":
    # Replace this process so the runner still owns Git's PID, pipes, exit code
    # and timeout. No shell, argument reconstruction or extra child process.
    os.execvpe("git", ["git", *sys.argv[1:]], git_environment())
