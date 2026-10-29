#!/usr/bin/env python3
"""Unit tests for tools/start_game.py (no network, no Godot, no cloudflared)."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import start_game  # noqa: E402

CLOUDFLARED_BANNER = """\
2026-10-29T01:38:01Z INF Requesting new quick Tunnel on trycloudflare.com...
2026-10-29T01:38:05Z INF +--------------------------------------------------------------------------------------------+
2026-10-29T01:38:05Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
2026-10-29T01:38:05Z INF |  https://encouraged-belts-lately-back.trycloudflare.com                                    |
2026-10-29T01:38:05Z INF +--------------------------------------------------------------------------------------------+
"""


class FindTunnelUrlTest(unittest.TestCase):
    def test_reads_the_url_from_the_banner(self) -> None:
        self.assertEqual(
            start_game.find_tunnel_url(CLOUDFLARED_BANNER),
            "https://encouraged-belts-lately-back.trycloudflare.com",
        )

    def test_ignores_the_api_host_before_the_tunnel_exists(self) -> None:
        self.assertIsNone(start_game.find_tunnel_url("INF Requesting new quick Tunnel on trycloudflare.com..."))
        self.assertIsNone(start_game.find_tunnel_url('ERR failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel"'))


class BuildIsCurrentTest(unittest.TestCase):
    STAMP = {"commit": "abc", "dirty": False}

    def test_clean_build_of_head_is_reused(self) -> None:
        self.assertTrue(start_game.build_is_current(self.STAMP, "abc", dirty=False, has_build=True))

    def test_other_commit_rebuilds(self) -> None:
        self.assertFalse(start_game.build_is_current(self.STAMP, "def", dirty=False, has_build=True))

    def test_dirty_tree_always_rebuilds(self) -> None:
        self.assertFalse(start_game.build_is_current(self.STAMP, "abc", dirty=True, has_build=True))

    def test_build_from_a_dirty_tree_is_not_reused_after_commit(self) -> None:
        stamp = {"commit": "abc", "dirty": True}
        self.assertFalse(start_game.build_is_current(stamp, "abc", dirty=False, has_build=True))

    def test_missing_export_or_stamp_rebuilds(self) -> None:
        self.assertFalse(start_game.build_is_current(self.STAMP, "abc", dirty=False, has_build=False))
        self.assertFalse(start_game.build_is_current(None, "abc", dirty=False, has_build=True))


class StagedFilesTest(unittest.TestCase):
    def test_skips_the_zip_and_import_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("index.html", "index.wasm", "LICENSE", "index.png.import", "neondrift-web-0.1.0.zip"):
                (root / name).write_text("x")
            (root / "nested").mkdir()
            self.assertEqual(
                [path.name for path in start_game.staged_files(root)],
                ["LICENSE", "index.html", "index.wasm"],
            )


class CloudflaredCandidatesTest(unittest.TestCase):
    def test_order_is_flag_env_path_then_cache(self) -> None:
        def which(name: str) -> Optional[str]:
            return "/usr/bin/cloudflared" if name == "cloudflared" else None

        found = start_game.cloudflared_candidates("/opt/cf", {"CLOUDFLARED": "/env/cf"}, which)
        self.assertEqual(
            found,
            [Path("/opt/cf"), Path("/env/cf"), Path("/usr/bin/cloudflared"), start_game.CACHED_CLOUDFLARED],
        )

    def test_falls_back_to_the_cache_only(self) -> None:
        self.assertEqual(
            start_game.cloudflared_candidates(None, {}, lambda _name: None),
            [start_game.CACHED_CLOUDFLARED],
        )


class ParseSessionTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        data = {
            "commit": "abc",
            "port": 8790,
            "url": "https://x.trycloudflare.com",
            "server_pid": 10,
            "tunnel_pid": 11,
            "started_at": "now",
        }
        session = start_game.parse_session(data)
        self.assertEqual(session.page, "https://x.trycloudflare.com/index.html")
        self.assertEqual(session.port, 8790)

    def test_malformed_state_is_an_error(self) -> None:
        with self.assertRaises(start_game.StartGameError):
            start_game.parse_session({"commit": "abc", "port": "not-a-port"})


class ProcessTest(unittest.TestCase):
    def test_terminate_only_matches_the_expected_command(self) -> None:
        child = subprocess.Popen((sys.executable, "-c", "import time; time.sleep(30)"))
        try:
            self.assertFalse(start_game.terminate(child.pid, "cloudflared"))
            self.assertIsNone(child.poll())
            self.assertTrue(start_game.terminate(child.pid, "time.sleep"))
            self.assertIsNotNone(child.wait(timeout=10))
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_stop_without_state_reports_nothing_running(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(start_game, "STATE_DIR", Path(tmp)):
            self.assertFalse(start_game.stop_session(quiet=True))

    def test_port_helpers(self) -> None:
        port = start_game.free_port()
        self.assertGreater(port, 0)
        self.assertTrue(start_game.port_is_free(port))


class SessionSourceTest(unittest.TestCase):
    def test_old_state_without_source_defaults_to_current(self) -> None:
        data = {"commit": "a", "port": 1, "url": "", "server_pid": 1, "tunnel_pid": 2, "started_at": "t"}
        self.assertEqual(start_game.parse_session(data).source, "current")
        self.assertEqual(start_game.parse_session({**data, "source": "main"}).source, "main")


class PlayCheckoutTest(unittest.TestCase):
    """A throwaway repository with an origin: the play worktree follows origin/main."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.origin = base / "origin.git"
        self.repo = base / "repo"
        self.play = base / "play"
        run = lambda *args, cwd=base: subprocess.run(args, cwd=cwd, check=True, capture_output=True)
        self.run = run
        run("git", "init", "-q", "--bare", "-b", "main", str(self.origin))
        run("git", "init", "-q", "-b", "main", str(self.repo))
        for key, value in (("user.name", "t"), ("user.email", "t@example.com")):
            run("git", "config", key, value, cwd=self.repo)
        (self.repo / "tools").mkdir()
        (self.repo / ".tools").mkdir()
        (self.repo / ".gitignore").write_text("/.tools\n")
        (self.repo / "a.txt").write_text("one\n")
        run("git", "add", ".gitignore", "a.txt", cwd=self.repo)
        run("git", "commit", "-q", "-m", "one", cwd=self.repo)
        run("git", "remote", "add", "origin", str(self.origin), cwd=self.repo)
        run("git", "push", "-q", "origin", "main", cwd=self.repo)
        patcher = mock.patch.object(start_game, "ROOT", self.repo)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _git(self, *args: str, cwd: Path) -> str:
        return subprocess.run(("git", *args), cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def test_creates_then_follows_origin_main_without_touching_the_caller(self) -> None:
        with mock.patch.dict("os.environ"):
            # CI sets GODOT_BIN, which deliberately skips the .tools link.
            os.environ.pop("GODOT_BIN", None)
            checkout = start_game.prepare_main_checkout(self.play)
        self.assertEqual((checkout / "a.txt").read_text(), "one\n")
        self.assertTrue((checkout / ".tools").is_symlink())
        # A new commit lands on origin/main while the caller works on another branch.
        self.run("git", "switch", "-q", "-c", "work", cwd=self.repo)
        (self.repo / "wip.txt").write_text("uncommitted\n")
        other = Path(self.tmp.name) / "other"
        self.run("git", "clone", "-q", str(self.origin), str(other))
        for key, value in (("user.name", "t"), ("user.email", "t@example.com")):
            self.run("git", "config", key, value, cwd=other)
        (other / "a.txt").write_text("two\n")
        self.run("git", "commit", "-q", "-am", "two", cwd=other)
        self.run("git", "push", "-q", "origin", "main", cwd=other)
        start_game.prepare_main_checkout(self.play)
        self.assertEqual((self.play / "a.txt").read_text(), "two\n")
        self.assertEqual(self._git("rev-parse", "HEAD", cwd=self.play), self._git("rev-parse", "origin/main", cwd=self.repo))
        self.assertEqual(self._git("branch", "--show-current", cwd=self.repo), "work")
        self.assertTrue((self.repo / "wip.txt").exists())

    def test_refuses_a_dirty_play_checkout(self) -> None:
        start_game.prepare_main_checkout(self.play)
        (self.play / "a.txt").write_text("edited\n")
        with self.assertRaises(start_game.StartGameError):
            start_game.prepare_main_checkout(self.play)

    def test_refuses_a_foreign_directory(self) -> None:
        self.play.mkdir()
        (self.play / "notes.txt").write_text("mine\n")
        with self.assertRaises(start_game.StartGameError):
            start_game.prepare_main_checkout(self.play)


if __name__ == "__main__":
    unittest.main()
