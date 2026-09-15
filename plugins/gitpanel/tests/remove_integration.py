#!/usr/bin/env python3
"""R04A recoverable helper only; every mutation is in a new owned Git fixture."""
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parent.parent / "remove.py"
spec = importlib.util.spec_from_file_location("remove_helper", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def fields(data):
    result = []
    for _ in range(3):
        size, data = data.split(b"\n", 1)
        size = int(size)
        result.append(data[:size])
        data = data[size:]
    assert not data
    return result


class RemoveIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gitpanel-remove-owned-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(HOME=str(self.base), XDG_CONFIG_HOME=str(self.base), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="test@invalid",
                        GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="test@invalid")
        self.git("init", "-b", "main")
        (self.root / "neighbor").write_bytes(b"HEAD\n")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        (self.root / "neighbor").write_bytes(b"INDEX\n")
        self.git("add", "neighbor")
        (self.root / "neighbor").write_bytes(b"working\n")
        self.file = self.root / "new"
        self.file.write_bytes(b"original\n")
        self.recovery = self.root / ".git" / helper.RECOVERY

    def git(self, *args):
        return subprocess.check_output(["git", "--no-optional-locks", "--literal-pathspecs", "-c", "diff.autoRefreshIndex=false",
                                        "-C", str(self.root), *args], env=self.env, stderr=subprocess.PIPE)

    def call(self, action, path="new", token=b"", root=None, env=None, data=None):
        return subprocess.run([sys.executable, "-I", str(HELPER), action, str(root or self.root), path],
                              input=(helper.pack([token]) if action == "remove" else b"") if data is None else data,
                              capture_output=True, env=env or self.env, timeout=20)

    def snapshot(self, path="new"):
        result = self.call("snapshot", path)
        self.assertEqual(result.returncode, 0, result.stderr)
        return fields(result.stdout)[2]

    def state(self):
        return ((self.root / ".git/index").read_bytes(), self.git("rev-parse", "HEAD"),
                self.git("show", ":neighbor"), (self.root / "neighbor").read_bytes())

    def entry(self):
        entries = list(self.recovery.iterdir())
        self.assertEqual(len(entries), 1)
        return entries[0]

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"Remove refused:", result.stderr)

    def local_remove(self, callback):
        """Fault injection is test-only, in-process; there are no production hooks."""
        with mock.patch.dict(os.environ, self.env, clear=True), ExitStack() as stack:
            repo = helper.Repository(str(self.root), "new", stack)
            token = repo.snapshot()[2]
            return callback(repo, token)

    def test_normal_empty_unicode_literal_recovery_and_raw_index(self):
        before = self.state()
        for path, data, mode in [("new", b"new\n", 0o644), ("empty", b"", 0o600),
                                 ("nested/literal\n雪:(glob)*[?]", b"\x00exact\xff\r\n", 0o751),
                                 ("-leading", b"dash", 0o640)]:
            with self.subTest(path=path):
                file = self.root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(data)
                file.chmod(mode)
                token = self.snapshot(path)
                self.assertEqual(self.state(), before, "snapshot must not touch raw index")
                result = self.call("remove", path, token)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = fields(result.stdout)
                entry = Path(os.fsdecode(receipt[0]))
                self.assertEqual(receipt[1:], [os.fsencode(path), b"removed"])
                self.assertEqual(entry.parent, self.recovery)
                self.assertFalse(file.exists())
                for name in ("snapshot", "content"):
                    self.assertEqual((entry / name).read_bytes(), data)
                    self.assertEqual((entry / name).stat().st_mode & 0o777, mode)
                metadata = json.loads((entry / "metadata.json").read_text())
                self.assertEqual(metadata["path"], path)
                self.assertEqual(metadata["mode"], mode)
                self.assertEqual(metadata["sha256"], helper.hashlib.sha256(data).hexdigest())
                self.assertEqual(entry.stat().st_mode & 0o777, 0o700)
                self.assertEqual((entry / "metadata.json").stat().st_mode & 0o777, 0o600)
                self.assertEqual(self.state(), before)
                self.assertFalse((self.root / ".git/index.lock").exists())
                self.assert_refused(self.call("remove", path, token))
                self.assertEqual((entry / "content").read_bytes(), data)
        self.assertEqual(len(list(self.recovery.iterdir())), 4)

    def test_existing_lock_is_not_removed(self):
        token = self.snapshot()
        lock = self.root / ".git/index.lock"
        lock.write_bytes(b"external lock")
        before = self.state()
        self.assert_refused(self.call("remove", token=token))
        self.assertEqual(lock.read_bytes(), b"external lock")
        self.assertEqual(self.file.read_bytes(), b"original\n")
        self.assertEqual(self.state(), before)
        self.assertFalse(self.recovery.exists())

    def test_staged_new_and_head_tracked_and_late_add(self):
        token = self.snapshot()
        self.git("add", "new")
        before = self.state()
        result = self.call("remove", token=token)
        self.assert_refused(result)
        self.assertIn(b"Unstage first", result.stderr)
        self.assert_refused(self.call("snapshot"))
        self.assertEqual(self.state(), before)
        self.git("reset", "-q", "HEAD", "--", "new")
        self.assertEqual(len(self.snapshot()), 64)
        self.assert_refused(self.call("snapshot", "neighbor"))
        self.git("rm", "--cached", "-f", "neighbor")
        self.assertIn(b"HEAD-tracked", self.call("snapshot", "neighbor").stderr)
        self.assertEqual(self.file.read_bytes(), b"original\n")

    def test_ignored_and_late_ignore(self):
        token = self.snapshot()
        (self.root / ".git/info/exclude").write_text("new\n")
        before = self.state()
        self.assert_refused(self.call("snapshot"))
        self.assert_refused(self.call("remove", token=token))
        self.assertEqual(self.state(), before)
        self.assertEqual(self.file.read_bytes(), b"original\n")

    def test_stale_bytes_mode_and_same_bytes_replacement(self):
        for change in (lambda: self.file.write_bytes(b"changed"), lambda: self.file.chmod(0o755),
                       lambda: (self.file.unlink(), self.file.write_bytes(b"changed"))):
            token = self.snapshot()
            change()
            before, data = self.state(), self.file.read_bytes()
            self.assert_refused(self.call("remove", token=token))
            self.assertEqual(self.file.read_bytes(), data)
            self.assertEqual(self.state(), before)
        self.assertFalse(self.recovery.exists())

    def test_unsafe_paths_links_and_special_files(self):
        for path in ("../new", "./new", "/new", ".git/config", ".GIT/config", "a/../new", "a//new", "new/", ""):
            with self.subTest(path=path):
                self.assert_refused(self.call("snapshot", path))
        self.file.unlink()
        self.file.symlink_to("neighbor")
        self.assert_refused(self.call("snapshot"))
        self.file.unlink()
        os.link(self.root / "neighbor", self.file)
        self.assert_refused(self.call("snapshot"))
        self.file.unlink()
        self.file.mkdir()
        self.assert_refused(self.call("snapshot"))
        self.file.rmdir()
        os.mkfifo(self.file)
        self.assert_refused(self.call("snapshot"))
        self.file.unlink()
        (self.root / "alias").symlink_to(self.root, target_is_directory=True)
        self.assert_refused(self.call("snapshot", "alias/neighbor"))
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assert_refused(self.call("snapshot", root=alias))

    def test_sparse_split_linked_nested_and_redirected_environment(self):
        self.git("config", "core.sparseCheckout", "true")
        self.assert_refused(self.call("snapshot"))
        self.git("config", "core.sparseCheckout", "false")
        self.git("update-index", "--split-index")
        self.assert_refused(self.call("snapshot"))
        self.git("update-index", "--no-split-index")
        linked = self.base / "linked"
        self.git("worktree", "add", "--detach", str(linked), "HEAD")
        (linked / "new").write_bytes(b"linked")
        self.assert_refused(self.call("snapshot", root=linked))
        nested = self.root / "nested"
        nested.mkdir()
        subprocess.check_call(["git", "--no-optional-locks", "-c", "diff.autoRefreshIndex=false", "init", str(nested)], env=self.env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (nested / "new").write_bytes(b"nested")
        self.assert_refused(self.call("snapshot", "nested/new"))
        for key in ("GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_LITERAL_PATHSPECS"):
            result = self.call("snapshot", env=dict(self.env, **{key: "unsafe"}))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(fields(result.stdout)[2]), 64)

    def test_unborn_repository_without_index(self):
        root = self.base / "unborn"
        root.mkdir()
        subprocess.check_call(["git", "--no-optional-locks", "-c", "diff.autoRefreshIndex=false", "init", str(root)], env=self.env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (root / "new").write_bytes(b"first")
        result = self.call("snapshot", root=root)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.call("remove", root=root, token=fields(result.stdout)[2])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((root / ".git/index").exists())
        self.assertEqual((Path(os.fsdecode(fields(result.stdout)[0])) / "content").read_bytes(), b"first")

    def test_recovery_parent_symlink_and_nonprivate_refused(self):
        token = self.snapshot()
        target = self.base / "private"
        target.mkdir()
        self.recovery.symlink_to(target, target_is_directory=True)
        self.assert_refused(self.call("remove", token=token))
        self.assertEqual(list(target.iterdir()), [])
        self.recovery.unlink()
        self.recovery.mkdir(mode=0o755)
        self.assert_refused(self.call("remove", token=token))
        self.assertEqual(self.file.read_bytes(), b"original\n")

    def test_unique_entry_collision_never_overwrites(self):
        self.recovery.mkdir(mode=0o700)
        entry = self.recovery / ("entry-" + "ab" * 16)
        entry.mkdir(mode=0o700)
        (entry / "metadata.json").write_bytes(b"prior backup")
        def run(repo, token):
            with mock.patch.object(helper.os, "urandom", return_value=bytes.fromhex("ab" * 16)):
                with self.assertRaises(FileExistsError):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual((entry / "metadata.json").read_bytes(), b"prior backup")
        self.assertEqual(self.file.read_bytes(), b"original\n")

    def test_metadata_failure_retains_source_and_snapshot(self):
        def run(repo, token):
            real = repo.write_checked
            def fail(parent, name, data, mode):
                if name == "metadata.json":
                    raise OSError("injected metadata failure")
                return real(parent, name, data, mode)
            with mock.patch.object(repo, "write_checked", side_effect=fail):
                with self.assertRaisesRegex(RuntimeError, "metadata failure.*recovery:"):
                    repo.remove(token)
        before = self.state()
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"original\n")
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")
        self.assertFalse((self.entry() / "content").exists())
        self.assertEqual(self.state(), before)

    def test_changed_under_lock_and_after_metadata_refused(self):
        def run(repo, token):
            real = repo.snapshot
            calls = []
            def changing():
                calls.append(1)
                if len(calls) == 2:
                    self.file.write_bytes(b"under lock")
                return real()
            with mock.patch.object(repo, "snapshot", side_effect=changing):
                with self.assertRaisesRegex(ValueError, "Changed under index lock"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"under lock")
        self.assertFalse(self.recovery.exists())
        def later(repo, token):
            real = repo.write_checked
            def changing(parent, name, data, mode):
                real(parent, name, data, mode)
                if name == "metadata.json":
                    self.file.write_bytes(b"after metadata")
            with mock.patch.object(repo, "write_checked", side_effect=changing):
                with self.assertRaisesRegex(RuntimeError, "Changed before move.*recovery:"):
                    repo.remove(token)
        self.local_remove(later)
        self.assertEqual(self.file.read_bytes(), b"after metadata")
        self.assertFalse((self.entry() / "content").exists())

    def test_late_changed_content_preserved_without_false_success(self):
        before = self.state()
        real = helper.exclusive_move
        def late(*args):
            self.file.write_bytes(b"late bytes")
            real(*args)
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=late):
                with self.assertRaisesRegex(RuntimeError, "Late file change.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertFalse(self.file.exists())
        self.assertEqual((self.entry() / "content").read_bytes(), b"late bytes")
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")
        self.assertEqual(self.state(), before)

    def test_late_replacement_before_move_preserves_both_versions(self):
        real = helper.exclusive_move
        def late(*args):
            self.file.unlink()
            self.file.write_bytes(b"replacement")
            real(*args)
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=late):
                with self.assertRaisesRegex(RuntimeError, "Late file change.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual((self.entry() / "content").read_bytes(), b"replacement")
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")

    def test_recreated_original_after_move_is_never_overwritten(self):
        real = helper.exclusive_move
        def late(*args):
            real(*args)
            self.file.write_bytes(b"new original")
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=late):
                with self.assertRaisesRegex(RuntimeError, "Original path recreated.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"new original")
        self.assertEqual((self.entry() / "content").read_bytes(), b"original\n")

    def test_destination_collision_and_cross_device_failure_preserve_all(self):
        real = helper.exclusive_move
        def collision(src, leaf, dst, name):
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dst)
            os.write(fd, b"prior content")
            os.close(fd)
            real(src, leaf, dst, name)
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=collision):
                with self.assertRaisesRegex(RuntimeError, "recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"original\n")
        self.assertEqual((self.entry() / "content").read_bytes(), b"prior content")
        def cross(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=OSError(18, "Cross-device link")):
                with self.assertRaisesRegex(RuntimeError, "Cross-device.*recovery:"):
                    repo.remove(token)
        self.local_remove(cross)
        self.assertEqual(self.file.read_bytes(), b"original\n")

    # Cooperative locking: replacement is detected before cleanup. This does not
    # prove atomic stat/unlink ownership against replacement in that final gap.
    def test_replaced_lock_preserved_on_failure(self):
        real = helper.exclusive_move
        lock = self.root / ".git/index.lock"
        def late(*args):
            real(*args)
            lock.unlink()
            lock.write_bytes(b"replacement lock")
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=late):
                with self.assertRaisesRegex(RuntimeError, "lock ownership lost.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(lock.read_bytes(), b"replacement lock")
        self.assertEqual((self.entry() / "content").read_bytes(), b"original\n")

    def test_parent_identity_change_before_move_is_refused(self):
        real = helper.Repository.write_checked
        old_git = self.root / ".git-old"
        def changing(repo, parent, name, data, mode):
            real(repo, parent, name, data, mode)
            if name == "metadata.json":
                (self.root / ".git").rename(old_git)
                (self.root / ".git").mkdir()
        def run(repo, token):
            with mock.patch.object(helper.Repository, "write_checked", changing):
                with self.assertRaisesRegex(RuntimeError, "Directory identity changed.*recovery:"):
                    repo.remove(token)
        try:
            self.local_remove(run)
            self.assertEqual(self.file.read_bytes(), b"original\n")
            self.assertFalse((old_git / "index.lock").exists())
        finally:
            if old_git.exists():
                (self.root / ".git").rmdir()
                old_git.rename(self.root / ".git")
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")

    def test_private_recovery_acl_refusal(self):
        self.recovery.mkdir(mode=0o700)
        if sys.platform == "darwin":
            subprocess.check_call(["chmod", "+a", "everyone allow read,search", str(self.recovery)], env=self.env)
            try:
                self.assert_refused(self.call("remove", token=self.snapshot()))
                self.assertEqual(list(self.recovery.iterdir()), [])
            finally:
                subprocess.check_call(["chmod", "-N", str(self.recovery)], env=self.env)
        def run(repo, token):
            with mock.patch.object(helper, "private_permissions", side_effect=ValueError("Cannot verify private recovery ACLs")):
                with self.assertRaisesRegex(ValueError, "private recovery ACLs"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"original\n")

    def test_recovery_metadata_tamper_before_move_refused(self):
        def run(repo, token):
            real = repo.snapshot
            calls = []
            def tamper():
                calls.append(1)
                result = real()
                if len(calls) == 3:
                    (self.entry() / "metadata.json").write_bytes(b"tampered")
                return result
            with mock.patch.object(repo, "snapshot", side_effect=tamper):
                with self.assertRaisesRegex(RuntimeError, "Recovery metadata changed.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertEqual(self.file.read_bytes(), b"original\n")
        self.assertFalse((self.entry() / "content").exists())

    def test_late_symlink_is_preserved_not_followed(self):
        real = helper.exclusive_move
        before = self.state()
        def late(*args):
            self.file.unlink()
            self.file.symlink_to(self.root / "neighbor")
            real(*args)
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=late):
                with self.assertRaisesRegex(RuntimeError, "regular, nonlinked.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertTrue((self.entry() / "content").is_symlink())
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")
        self.assertEqual(self.state(), before)

    def test_uncertain_failure_after_move_retains_recovery(self):
        real = helper.exclusive_move
        def uncertain(*args):
            real(*args)
            raise OSError("injected uncertain completion")
        def run(repo, token):
            with mock.patch.object(helper, "exclusive_move", side_effect=uncertain):
                with self.assertRaisesRegex(RuntimeError, "uncertain completion.*recovery:"):
                    repo.remove(token)
        self.local_remove(run)
        self.assertFalse(self.file.exists())
        self.assertEqual((self.entry() / "snapshot").read_bytes(), b"original\n")
        self.assertEqual((self.entry() / "content").read_bytes(), b"original\n")
        self.assertFalse((self.root / ".git/index.lock").exists())

    def test_malformed_protocol_and_optimized_invocation(self):
        for data in (b"", b"-1\n", b"64\nshort", helper.pack([b"x" * 64, b"extra"])):
            self.assert_refused(self.call("remove", data=data))
        self.assert_refused(self.call("absence"))
        result = subprocess.run([sys.executable, "-I", "-O", str(HELPER), "snapshot", str(self.root), "new"],
                                capture_output=True, env=self.env, timeout=20)
        self.assert_refused(result)
        self.assertEqual(self.file.read_bytes(), b"original\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
