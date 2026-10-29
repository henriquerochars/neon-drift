"""Source, environment and gate fingerprints on temporary directories."""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent.lib import fingerprint as fp  # noqa: E402


class SourceFingerprintTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "src").mkdir()
        (self.root / "src" / "a.gd").write_text("extends Node\n")
        (self.root / "src" / "b c.gd").write_text("extends Node2D\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_stable_and_order_independent(self) -> None:
        one = fp.source_fingerprint(self.root, ["src/a.gd", "src/b c.gd"])
        two = fp.source_fingerprint(self.root, ["src/b c.gd", "src/a.gd", "src/a.gd"])
        self.assertEqual(one, two)
        self.assertEqual(len(one), 64)

    def test_content_change_changes_fingerprint(self) -> None:
        before = fp.source_fingerprint(self.root, ["src/a.gd"])
        (self.root / "src" / "a.gd").write_text("extends Node\nvar x := 1\n")
        self.assertNotEqual(before, fp.source_fingerprint(self.root, ["src/a.gd"]))

    def test_mode_change_changes_fingerprint(self) -> None:
        path = self.root / "src" / "a.gd"
        before = fp.source_fingerprint(self.root, ["src/a.gd"])
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        self.assertNotEqual(before, fp.source_fingerprint(self.root, ["src/a.gd"]))

    def test_deleted_entry(self) -> None:
        self.assertEqual(fp.file_entry(self.root, "src/missing.gd"), ("src/missing.gd", "", fp.DELETED))
        before = fp.source_fingerprint(self.root, ["src/a.gd"])
        (self.root / "src" / "a.gd").unlink()
        self.assertNotEqual(before, fp.source_fingerprint(self.root, ["src/a.gd"]))

    def test_only_listed_files_matter(self) -> None:
        before = fp.source_fingerprint(self.root, ["src/a.gd"])
        (self.root / "src" / "b c.gd").write_text("changed\n")
        self.assertEqual(before, fp.source_fingerprint(self.root, ["src/a.gd"]))

    def test_symlink_hashes_target_text(self) -> None:
        link = self.root / "src" / "link.gd"
        os.symlink("a.gd", link)
        entry = fp.file_entry(self.root, "src/link.gd")
        self.assertEqual(entry[2], fp.sha256_bytes(b"a.gd"))


class EnvironmentFingerprintTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _fake_godot(self, version: str) -> None:
        script = self.root / "tools" / "godot.sh"
        script.write_text(f"#!/bin/sh\necho '{version}'\n")
        script.chmod(0o755)

    def test_keys_and_missing_values(self) -> None:
        env = fp.environment_fingerprint(self.root)
        self.assertEqual(
            set(env),
            {"godot", "python3", "tools/agent", *fp.ENVIRONMENT_FILES},
        )
        self.assertEqual(env["godot"], fp.MISSING)
        self.assertEqual(env["project.godot"], fp.MISSING)
        self.assertTrue(env["python3"].startswith("Python "))
        for value in env.values():
            self.assertNotIn(os.environ.get("HOME", "\0"), value)

    def test_godot_version_is_first_line(self) -> None:
        self._fake_godot("4.7.2.stable.official.abc")
        self.assertEqual(fp.godot_version(self.root), "4.7.2.stable.official.abc")

    def test_pin_file_and_gate_code_change_fingerprint(self) -> None:
        base = fp.environment_fingerprint(self.root)
        (self.root / "tools" / "requirements-lint.txt").write_text("gdtoolkit==4.3.0\n")
        with_pin = fp.environment_fingerprint(self.root)
        self.assertNotEqual(base["tools/requirements-lint.txt"], with_pin["tools/requirements-lint.txt"])
        gate = self.root / "tools" / "agent" / "lib"
        gate.mkdir(parents=True)
        (gate / "x.py").write_text("A = 1\n")
        (self.root / "tools" / "agent" / "__pycache__").mkdir()
        (self.root / "tools" / "agent" / "__pycache__" / "x.pyc").write_bytes(b"ignored")
        first = fp.gate_code_hash(self.root)
        (self.root / "tools" / "agent" / "__pycache__" / "x.pyc").write_bytes(b"still ignored")
        self.assertEqual(first, fp.gate_code_hash(self.root))
        (gate / "x.py").write_text("A = 2\n")
        self.assertNotEqual(first, fp.gate_code_hash(self.root))


class GateFingerprintTest(unittest.TestCase):
    def test_every_input_matters(self) -> None:
        env = {"godot": "4.7.2.stable", "python3": "Python 3.9.6"}
        base = fp.gate_fingerprint("abc", "src", env, ["lint"])
        self.assertEqual(base, fp.gate_fingerprint("abc", "src", dict(reversed(list(env.items()))), ["lint"]))
        self.assertNotEqual(base, fp.gate_fingerprint("abd", "src", env, ["lint"]))
        self.assertNotEqual(base, fp.gate_fingerprint("abc", "src2", env, ["lint"]))
        self.assertNotEqual(base, fp.gate_fingerprint("abc", "src", {**env, "godot": "missing"}, ["lint"]))
        self.assertNotEqual(base, fp.gate_fingerprint("abc", "src", env, ["lint", "godot-tests"]))

    def test_short(self) -> None:
        self.assertEqual(fp.short("0123456789abcdef"), "0123456789ab…")


if __name__ == "__main__":
    unittest.main()
