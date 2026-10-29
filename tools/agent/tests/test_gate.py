"""End-to-end gate behaviour on temporary git repositories with fake check commands."""

from __future__ import annotations

import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Sequence

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from agent import check_changed as gate  # noqa: E402
from agent.lib import receipt as rc  # noqa: E402
from agent.lib.selection import CHECK_ORDER  # noqa: E402
from agent.lib.worktree import get_worktree  # noqa: E402

GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
GIT_IDENTITY = ("-c", "user.name=Gate Test", "-c", "user.email=gate@example.invalid", "-c", "commit.gpgsign=false")
IGNORE = ".neondrift/\n.venv/\ntools/godot.sh\ntools/requirements-lint.txt\n"
FAKE_GODOT = "4.7.2.stable.fake"


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *GIT_IDENTITY, *args],
        cwd=str(root),
        capture_output=True,
        text=True,
        check=True,
        env={**os.environ, **GIT_ENV},
    )
    return result.stdout.strip()


def py_command(code: str) -> list[str]:
    return [sys.executable, "-c", code]


class GateFixture(unittest.TestCase):
    """A repository with one commit on main, a fake origin/main and a fake Godot."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.outside = Path(tempfile.mkdtemp())
        self.counter = self.outside / "counter"
        git(self.root, "init", "--quiet")
        git(self.root, "symbolic-ref", "HEAD", "refs/heads/main")
        (self.root / "src").mkdir()
        (self.root / "docs").mkdir()
        (self.root / "data" / "balance").mkdir(parents=True)
        (self.root / "tools").mkdir()
        (self.root / "src" / "a.gd").write_text("extends Node\n")
        (self.root / "docs" / "GDD.md").write_text("# GDD\n")
        (self.root / "data" / "balance" / "enemies.csv").write_text("id,hp\nrat,1\n")
        (self.root / ".gitignore").write_text(IGNORE)
        git(self.root, "add", "-A")
        git(self.root, "commit", "--quiet", "-m", "init")
        self.base_sha = git(self.root, "rev-parse", "HEAD")
        git(self.root, "update-ref", "refs/remotes/origin/main", self.base_sha)
        self.fake_godot(FAKE_GODOT)
        self.commands = {check: [self.count_command()] for check in CHECK_ORDER}

    def tearDown(self) -> None:
        self.tmp.cleanup()
        for child in self.outside.iterdir():
            child.unlink()
        self.outside.rmdir()

    # helpers ------------------------------------------------------------------------

    def fake_godot(self, version: str | None) -> None:
        script = self.root / "tools" / "godot.sh"
        if version is None:
            script.unlink(missing_ok=True)
            return
        script.write_text(f"#!/bin/sh\necho '{version}'\n")
        script.chmod(0o755)

    def count_command(self, exit_code: int = 0, extra: str = "") -> list[str]:
        return py_command(
            f"open({str(self.counter)!r}, 'a').write('x'); {extra or 'pass'}; raise SystemExit({exit_code})"
        )

    def runs(self) -> int:
        return len(self.counter.read_text()) if self.counter.exists() else 0

    def run_gate(self, *argv: str, commands: dict[str, Sequence[Sequence[str]]] | None = None) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gate.main(list(argv), commands=commands or self.commands, cwd=self.root)
        return code, out.getvalue(), err.getvalue()

    def scope(self, base: str = "origin/main") -> gate.Scope:
        return gate.compute_scope(get_worktree(self.root), base)

    def latest(self) -> rc.Receipt:
        receipt = rc.read_latest(get_worktree(self.root))
        assert receipt is not None
        return receipt

    def touch_source(self, text: str = "var x := 1\n") -> None:
        with (self.root / "src" / "a.gd").open("a") as handle:
            handle.write(text)


class ChangedSetTest(GateFixture):
    def test_staged_unstaged_untracked_deleted_renamed_and_spaces(self) -> None:
        self.touch_source()  # unstaged
        (self.root / "src" / "staged.gd").write_text("extends Node\n")
        git(self.root, "add", "src/staged.gd")  # staged
        (self.root / "src" / "my file.tscn").write_text("[gd_scene]\n")  # untracked with a space
        git(self.root, "mv", "data/balance/enemies.csv", "data/balance/rats.csv")  # rename
        (self.root / "docs" / "GDD.md").unlink()  # deletion
        (self.root / ".neondrift").mkdir(exist_ok=True)
        (self.root / "src" / "noise.log").write_text("ignored\n")
        scope = self.scope()
        self.assertEqual(
            scope.paths,
            [
                "data/balance/enemies.csv",
                "data/balance/rats.csv",
                "docs/GDD.md",
                "src/a.gd",
                "src/my file.tscn",
                "src/staged.gd",
            ],
        )
        self.assertEqual(scope.checks, ["record", "lint", "balance", "godot-tests"])
        self.assertEqual(scope.baseline.sha, self.base_sha)

    def test_commits_on_the_branch_count(self) -> None:
        self.touch_source()
        git(self.root, "commit", "--quiet", "-am", "edit")
        scope = self.scope()
        self.assertEqual(scope.paths, ["src/a.gd"])
        self.assertNotEqual(scope.baseline.head_sha, self.base_sha)
        self.assertEqual(scope.baseline.sha, self.base_sha)

    def test_missing_baseline_exits_2(self) -> None:
        code, out, err = self.run_gate("--base", "origin/nope")
        self.assertEqual(code, 2)
        self.assertIn("git fetch origin main", err)
        self.assertIn("--base", err)
        code, out, err = self.run_gate("--status", "--quiet", "--base", "origin/nope")
        self.assertEqual(code, 2)
        self.assertEqual(out.strip(), "gate: none")


class RunTest(GateFixture):
    def test_prose_only_passes_without_steps(self) -> None:
        (self.root / "README.md").write_text("# Readme\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.runs(), 0)
        receipt = self.latest()
        self.assertEqual(receipt.status, rc.STATUS_PASS)
        self.assertEqual(receipt.steps, [])
        self.assertEqual(receipt.checks, [])
        self.assertIn("checks: (none)", out)

    def test_docs_only_runs_the_record_check(self) -> None:
        (self.root / "docs" / "GDD.md").write_text("# GDD v2\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.runs(), 1)
        self.assertEqual(self.latest().checks, ["record"])
        self.assertIn("checks: record", out)
        self.assertNotIn("changed but docs/STATUS.md did not", out)

    def test_source_change_without_the_record_prints_an_advisory(self) -> None:
        self.touch_source()
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertIn("record: 1 file(s) under src/ or data/ changed but docs/STATUS.md did not", out)
        code, out, _ = self.run_gate("--status", "--json")
        self.assertEqual(code, 0, out)
        self.assertEqual(len(json.loads(out)["advisories"]), 1)
        (self.root / "docs" / "STATUS.md").write_text("# Status\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertNotIn("changed but docs/STATUS.md did not", out)
        self.assertEqual(self.latest().checks, ["record", "lint", "godot-tests"])

    def test_pass_receipt_is_reused_and_force_reruns(self) -> None:
        self.touch_source()
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.runs(), 2)  # lint + godot-tests
        self.assertIn("baseline: origin/main", out)
        self.assertIn("changed files: 1", out)
        self.assertIn("checks: lint, godot-tests", out)
        receipt = self.latest()
        self.assertEqual([s.check for s in receipt.steps], ["lint", "godot-tests"])
        self.assertEqual(receipt.baseline_sha, self.base_sha)
        self.assertEqual(receipt.head_sha, self.base_sha)
        for step in receipt.steps:
            self.assertTrue((self.root / step.log).is_file(), step.log)
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertIn("reused", out)
        self.assertEqual(self.runs(), 2)
        code, out, _ = self.run_gate("--force")
        self.assertEqual(code, 0)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 4)

    def test_content_change_invalidates(self) -> None:
        self.touch_source()
        self.run_gate()
        self.touch_source("var y := 2\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 4)

    def test_mode_change_invalidates(self) -> None:
        self.touch_source()
        self.run_gate()
        path = self.root / "src" / "a.gd"
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 4)

    def test_toolchain_change_invalidates(self) -> None:
        self.touch_source()
        self.run_gate()
        self.fake_godot("4.7.2.stable.other")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 4)
        (self.root / "tools" / "requirements-lint.txt").write_text("gdtoolkit==4.3.1\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 6)

    def test_selected_checks_change_invalidates(self) -> None:
        self.touch_source()
        self.run_gate()
        (self.root / "data" / "balance" / "enemies.csv").write_text("id,hp\nrat,2\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertEqual(self.latest().checks, ["lint", "balance", "godot-tests"])
        self.assertEqual(self.runs(), 5)

    def test_failing_step_keeps_exit_code_and_is_not_reused_as_pass(self) -> None:
        self.touch_source()
        commands = dict(self.commands)
        commands["godot-tests"] = [self.count_command(exit_code=7)]
        code, out, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 1, out)
        receipt = self.latest()
        self.assertEqual(receipt.status, rc.STATUS_FAIL)
        self.assertEqual([(s.check, s.exit_code) for s in receipt.steps], [("lint", 0), ("godot-tests", 7)])
        self.assertEqual(self.runs(), 2)
        code, out, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 1)
        self.assertIn("recorded failure", out)
        self.assertNotIn("reused", out)
        self.assertEqual(self.runs(), 2)
        code, out, _ = self.run_gate("--retry", commands=commands)
        self.assertEqual(code, 1)
        self.assertEqual(self.runs(), 4)
        commands["godot-tests"] = [self.count_command()]
        code, out, _ = self.run_gate("--retry", commands=commands)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.latest().status, rc.STATUS_PASS)

    def test_multiple_commands_stop_at_first_failure(self) -> None:
        self.touch_source()
        commands = dict(self.commands)
        commands["lint"] = [self.count_command(exit_code=3), self.count_command()]
        code, _, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 1)
        self.assertEqual(self.runs(), 2)  # lint's first command + godot-tests
        self.assertEqual(self.latest().steps[0].exit_code, 3)

    def test_balance_engine_error_scan_fails_exit_zero(self) -> None:
        (self.root / "data" / "balance" / "enemies.csv").write_text("id,hp\nrat,2\n")
        commands = dict(self.commands)
        commands["balance"] = [py_command("print('\\x1b[31mERROR: res://data/x.tres failed\\x1b[0m')")]
        code, _, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 1)
        steps = {s.check: s.exit_code for s in self.latest().steps}
        self.assertEqual(steps, {"lint": 0, "balance": 1, "godot-tests": 0})
        log = (self.root / self.latest().steps[1].log).read_text()
        self.assertIn("ERROR: res://data/x.tres failed", log)
        self.assertIn("engine errors", log)
        commands["balance"] = [py_command("print('Exit code: 0'); print('no errors here')")]
        code, _, _ = self.run_gate("--retry", commands=commands)
        self.assertEqual(code, 0)

    def test_edit_during_run_is_stale(self) -> None:
        self.touch_source()
        target = self.root / "src" / "a.gd"
        commands = dict(self.commands)
        commands["lint"] = [self.count_command(extra=f"open({str(target)!r}, 'a').write('edited')")]
        code, out, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 3, out)
        self.assertEqual(self.latest().status, rc.STATUS_STALE)
        self.assertIn("gate: stale", out)
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 3)
        self.assertEqual(out.strip(), "gate: stale")
        code, out, _ = self.run_gate(commands=self.commands)
        self.assertEqual(code, 0, out)

    def test_missing_prerequisite_exits_4_with_fail_receipt(self) -> None:
        self.touch_source()
        self.fake_godot(None)
        code, out, _ = self.run_gate()
        self.assertEqual(code, 4, out)
        self.assertIn("tools/agent.sh bootstrap", out)
        self.assertEqual(self.runs(), 0)
        receipt = self.latest()
        self.assertEqual(receipt.status, rc.STATUS_FAIL)
        self.assertEqual([(s.check, s.exit_code) for s in receipt.steps], [(rc.PREREQUISITES_STEP, 4)])
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("gate: current fail"), out)
        code, _, _ = self.run_gate()
        self.assertEqual(code, 4)
        self.assertEqual(self.runs(), 0)
        self.fake_godot(FAKE_GODOT)  # bootstrap changes the environment fingerprint
        code, _, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertEqual(self.runs(), 2)

    def test_art_prerequisite_needs_validator(self) -> None:
        (self.root / "art").mkdir()
        (self.root / "art" / "x.png").write_bytes(b"\x89PNG")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 4)
        self.assertIn("tools/art/validate.py", out)
        (self.root / "tools" / "art").mkdir(parents=True)
        (self.root / "tools" / "art" / "validate.py").write_text("print('art OK')\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.latest().checks, ["lint", "art", "godot-tests"])

    def test_lint_only_change_needs_no_engine(self) -> None:
        self.fake_godot(None)
        (self.root / "tools" / "agent").mkdir()
        (self.root / "tools" / "agent" / "x.py").write_text("X = 1\n")
        code, out, _ = self.run_gate()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.latest().checks, ["harness"])

    def test_busy_when_another_fingerprint_holds_the_lock(self) -> None:
        self.touch_source()
        job_dir = self.root / ".neondrift" / "jobs" / "gate"
        job_dir.mkdir(parents=True)
        (job_dir / "lock.json").write_text(
            json.dumps({"pid": os.getpid(), "started_at": "now", "fingerprint": "other", "host": "h"})
        )
        code, out, _ = self.run_gate()
        self.assertEqual(code, 75, out)
        self.assertEqual(self.runs(), 0)
        (job_dir / "lock.json").unlink()
        code, _, _ = self.run_gate()
        self.assertEqual(code, 0)

    def test_unknown_check_in_table_is_a_usage_error(self) -> None:
        self.touch_source()
        code, _, err = self.run_gate(commands={"lint": [self.count_command()]})
        self.assertEqual(code, 2)
        self.assertIn("godot-tests", err)

    def test_command_that_cannot_start_fails_the_step(self) -> None:
        self.touch_source()
        commands = dict(self.commands)
        commands["lint"] = [[str(self.root / "tools" / "does-not-exist.sh")]]
        code, _, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 1)
        self.assertEqual(self.latest().steps[0].exit_code, 127)

    def test_relative_script_runs_from_worktree_root(self) -> None:
        self.touch_source()
        script = self.root / "tools" / "fake_check.sh"
        script.write_text("#!/bin/sh\ntest -f src/a.gd && echo from-root\n")
        script.chmod(0o755)
        git(self.root, "add", "tools/fake_check.sh")
        git(self.root, "commit", "--quiet", "-m", "fake check")
        git(self.root, "update-ref", "refs/remotes/origin/main", "HEAD")
        commands = dict(self.commands)
        commands["lint"] = [["tools/fake_check.sh"]]
        code, out, _ = self.run_gate(commands=commands)
        self.assertEqual(code, 0, out)
        self.assertIn("from-root", out)


class StatusTest(GateFixture):
    def test_status_outcomes(self) -> None:
        self.touch_source()
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 1)
        self.assertEqual(out.strip(), "gate: none")
        self.assertEqual(self.runs(), 0)

        self.run_gate()
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 0)
        self.assertRegex(out.strip(), r"^gate: current pass \([0-9a-f]{12}…\)$")
        self.assertEqual(self.runs(), 2)

        self.touch_source("var z := 3\n")
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 3)
        self.assertEqual(out.strip(), "gate: stale")

        commands = dict(self.commands)
        commands["lint"] = [self.count_command(exit_code=1)]
        self.run_gate(commands=commands)
        code, out, _ = self.run_gate("--status", "--quiet")
        self.assertEqual(code, 1)
        self.assertRegex(out.strip(), r"^gate: current fail \([0-9a-f]{12}…\)$")

    def test_status_json_and_verbose(self) -> None:
        self.touch_source()
        self.run_gate()
        code, out, _ = self.run_gate("--status", "--json")
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["gate"], "current pass")
        self.assertEqual(payload["receipt"]["status"], "pass")
        self.assertEqual(payload["receipt"]["checks"], ["lint", "godot-tests"])
        self.assertEqual(payload["baseline_sha"], self.base_sha)
        code, out, _ = self.run_gate("--status")
        self.assertEqual(code, 0)
        self.assertIn("baseline: origin/main", out)
        self.assertIn("godot-tests", out)
        self.assertIn("gate: current pass", out)

    def test_run_json_prints_receipt(self) -> None:
        self.touch_source()
        code, out, _ = self.run_gate("--json")
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["gate"], "pass")
        self.assertEqual(len(payload["receipt"]["steps"]), 2)
        self.assertIn("raise SystemExit(0)", (self.root / payload["receipt"]["steps"][0]["log"]).read_text())

    def test_quiet_run_prints_one_line(self) -> None:
        self.touch_source()
        code, out, _ = self.run_gate("--quiet")
        self.assertEqual(code, 0)
        self.assertRegex(out.strip(), r"^gate: pass \([0-9a-f]{12}…\)$")


if __name__ == "__main__":
    unittest.main()
