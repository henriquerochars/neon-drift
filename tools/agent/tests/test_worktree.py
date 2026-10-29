from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict
from unittest import mock

TOOLS_ROOT = Path(__file__).resolve().parents[2]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

from agent.lib import worktree as wt  # noqa: E402


def clean_env() -> Dict[str, str]:
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(cwd: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, check=True, env=clean_env(),
    )
    return proc.stdout


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    git(path, "-c", "init.defaultBranch=main", "init", "-q")
    git(path, "config", "user.name", "Harness Test")
    git(path, "config", "user.email", "harness@example.invalid")
    git(path, "config", "commit.gpgsign", "false")
    (path / ".gitignore").write_text("/.tools\n.neondrift/\n.godot/\n.venv/\n")
    (path / "README.md").write_text("fixture\n")
    git(path, "add", ".gitignore", "README.md")
    git(path, "commit", "-q", "-m", "init")
    return path.resolve()


def add_linked(primary: Path, path: Path, branch: str = "feat") -> Path:
    git(primary, "worktree", "add", "-q", "-b", branch, str(path))
    return path.resolve()


class WorktreeTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._env = mock.patch.dict(os.environ, clean_env(), clear=True)
        self._env.start()
        self.addCleanup(self._env.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.primary = make_repo(self.tmp / "primary")
        self.linked = add_linked(self.primary, self.tmp / "linked")


class IdentityTests(WorktreeTestCase):
    def test_primary_identity(self) -> None:
        w = wt.get_worktree(self.primary)
        self.assertEqual(w.root, self.primary)
        self.assertTrue(w.is_primary)
        self.assertEqual(w.primary_root, self.primary)
        self.assertEqual(w.git_dir, self.primary / ".git")
        self.assertEqual(w.common_dir, self.primary / ".git")
        self.assertEqual(w.state_dir, self.primary / ".neondrift")
        self.assertEqual(w.id, hashlib.sha256(str(w.git_dir).encode()).hexdigest()[:12])

    def test_linked_identity_and_distinct_ids(self) -> None:
        p = wt.get_worktree(self.primary)
        w = wt.get_worktree(self.linked)
        self.assertEqual(w.root, self.linked)
        self.assertFalse(w.is_primary)
        self.assertEqual(w.primary_root, self.primary)
        self.assertEqual(w.common_dir, self.primary / ".git")
        self.assertEqual(w.git_dir.parent, self.primary / ".git" / "worktrees")
        self.assertEqual(w.state_dir, self.linked / ".neondrift")
        self.assertEqual(len(w.id), 12)
        int(w.id, 16)
        self.assertNotEqual(w.id, p.id)

    def test_subdirectory_resolves_same_worktree(self) -> None:
        sub = self.linked / "a" / "b"
        sub.mkdir(parents=True)
        self.assertEqual(wt.get_worktree(sub), wt.get_worktree(self.linked))

    def test_default_cwd(self) -> None:
        old = os.getcwd()
        os.chdir(self.linked)
        try:
            self.assertEqual(wt.get_worktree().root, self.linked)
        finally:
            os.chdir(old)

    def test_not_a_repo(self) -> None:
        outside = self.tmp / "plain"
        outside.mkdir()
        with mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(self.tmp)}):
            with self.assertRaises(wt.WorktreeError):
                wt.get_worktree(outside)


class StateDirTests(WorktreeTestCase):
    def test_mode_and_gdignore(self) -> None:
        w = wt.get_worktree(self.linked)
        old_umask = os.umask(0o022)
        try:
            state = wt.ensure_state_dir(w)
        finally:
            os.umask(old_umask)
        self.assertEqual(state, self.linked / ".neondrift")
        self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
        gdignore = state / ".gdignore"
        self.assertTrue(gdignore.is_file())
        self.assertEqual(gdignore.read_bytes(), b"")

    def test_existing_dir_is_tightened_and_idempotent(self) -> None:
        w = wt.get_worktree(self.primary)
        w.state_dir.mkdir(mode=0o755)
        os.chmod(w.state_dir, 0o755)
        wt.ensure_state_dir(w)
        wt.ensure_state_dir(w)
        self.assertEqual(stat.S_IMODE(w.state_dir.stat().st_mode), 0o700)
        self.assertEqual(git(self.primary, "status", "--porcelain"), "")


class ToolsLinkTests(WorktreeTestCase):
    def test_links_when_missing_and_primary_has_tools(self) -> None:
        (self.primary / ".tools").mkdir()
        w = wt.get_worktree(self.linked)
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_CREATED)
        link = self.linked / ".tools"
        self.assertTrue(link.is_symlink())
        self.assertEqual(Path(os.readlink(link)), self.primary / ".tools")
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_EXISTS)
        # /.tools in .gitignore covers the symlink.
        self.assertEqual(git(self.linked, "status", "--porcelain"), "")

    def test_never_overwrites_existing_tools_dir(self) -> None:
        (self.primary / ".tools").mkdir()
        own = self.linked / ".tools"
        own.mkdir()
        (own / "mine").write_text("keep")
        w = wt.get_worktree(self.linked)
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_EXISTS)
        self.assertFalse(own.is_symlink())
        self.assertEqual((own / "mine").read_text(), "keep")

    def test_never_overwrites_broken_symlink(self) -> None:
        (self.primary / ".tools").mkdir()
        own = self.linked / ".tools"
        os.symlink(str(self.tmp / "gone"), str(own))
        w = wt.get_worktree(self.linked)
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_EXISTS)
        self.assertEqual(Path(os.readlink(own)), self.tmp / "gone")

    def test_no_source_in_primary(self) -> None:
        w = wt.get_worktree(self.linked)
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_NO_SOURCE)
        self.assertFalse(os.path.lexists(self.linked / ".tools"))

    def test_primary_is_never_linked(self) -> None:
        w = wt.get_worktree(self.primary)
        self.assertEqual(wt.link_primary_tools(w), wt.LINK_PRIMARY)
        self.assertFalse(os.path.lexists(self.primary / ".tools"))


if __name__ == "__main__":
    unittest.main()
