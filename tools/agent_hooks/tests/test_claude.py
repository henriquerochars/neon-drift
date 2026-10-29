"""Tests for the Claude Code adapter: PreToolUse mapping and output, Stop advisory."""

from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TOOLS_DIR))

from agent_hooks import claude, policy  # noqa: E402

ADAPTER = TOOLS_DIR / "agent_hooks" / "claude.py"


class AdapterCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.realpath(self.tmp.name)
        os.makedirs(os.path.join(self.root, "src"))
        os.makedirs(os.path.join(self.root, ".claude"))
        Path(self.root, "release.keystore").write_text("x\n")
        os.symlink("release.keystore", os.path.join(self.root, "alias.txt"))
        self.env = dict(os.environ, HOME="/home/guard-test-user", CLAUDE_PROJECT_DIR=self.root)
        self.env.pop("TMPDIR", None)

    def run_adapter(self, event: dict) -> tuple[int, str]:
        completed = subprocess.run(
            [sys.executable, str(ADAPTER)],
            input=json.dumps(event).encode("utf-8"),
            capture_output=True,
            env=self.env,
            cwd=self.root,
            check=False,
        )
        return completed.returncode, completed.stdout.decode("utf-8")

    def pre_tool(self, tool: str, tool_input: dict, cwd: str = "") -> dict:
        return {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "tool_name": tool,
            "tool_input": tool_input,
            "cwd": cwd or self.root,
        }

    def write_gate(self, body: str) -> None:
        script = Path(self.root, "tools", "agent", "check_changed.py")
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(body)
        script.chmod(script.stat().st_mode | stat.S_IXUSR)


class PreToolUseTest(AdapterCase):
    def test_deny_shape(self) -> None:
        code, out = self.run_adapter(self.pre_tool("Bash", {"command": "git reset --hard HEAD~1"}))
        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(out),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": policy.REASONS["destructive-command"][1],
                }
            },
        )

    def test_ask_shape(self) -> None:
        code, out = self.run_adapter(self.pre_tool("Bash", {"command": "git push --tags"}))
        self.assertEqual(code, 0)
        payload = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(payload["permissionDecision"], "ask")
        self.assertEqual(payload["permissionDecisionReason"], policy.REASONS["publication"][1])

    def test_allow_is_silent(self) -> None:
        for tool, tool_input in (
            ("Bash", {"command": "git status"}),
            ("Read", {"file_path": "src/player.gd"}),
            ("Write", {"file_path": "src/player.gd", "content": "x"}),
            ("Write", {"file_path": "/tmp/x", "content": "x"}),
            ("Grep", {"pattern": "x"}),
            ("Glob", {"pattern": "**/*.gd"}),
            ("WebFetch", {"url": "https://example.com"}),
            ("mcp__pixellab__create_character", {"description": "dog"}),
        ):
            with self.subTest(tool=tool, tool_input=tool_input):
                code, out = self.run_adapter(self.pre_tool(tool, tool_input))
                self.assertEqual((code, out), (0, ""))

    def test_read_tools_catch_secret_symlink(self) -> None:
        for tool, key in (("Read", "file_path"), ("Grep", "path"), ("Glob", "path")):
            with self.subTest(tool=tool):
                _, out = self.run_adapter(self.pre_tool(tool, {key: os.path.join(self.root, "alias.txt")}))
                self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")
        _, out = self.run_adapter(self.pre_tool("Read", {"file_path": "alias.txt"}))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_write_tools_ask_for_policy_and_outside_root(self) -> None:
        cases = (
            ("Write", {"file_path": ".claude/settings.json", "content": "{}"}),
            ("Edit", {"file_path": os.path.join(self.root, "CLAUDE.md"), "old_string": "a", "new_string": "b"}),
            ("MultiEdit", {"file_path": "AGENTS.md", "edits": []}),
            ("NotebookEdit", {"notebook_path": "/Users/someone/other/nb.ipynb", "new_source": ""}),
            ("Write", {"file_path": "/Users/someone/other/file", "content": "x"}),
        )
        for tool, tool_input in cases:
            with self.subTest(tool=tool):
                _, out = self.run_adapter(self.pre_tool(tool, tool_input))
                self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "ask")

    def test_relative_paths_resolve_against_cwd(self) -> None:
        sub = os.path.join(self.root, "src")
        _, out = self.run_adapter(self.pre_tool("Read", {"file_path": "../alias.txt"}, cwd=sub))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")
        _, out = self.run_adapter(self.pre_tool("Bash", {"command": "rm -rf .."}, cwd=sub))
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_malformed_input_denies(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(ADAPTER)], input=b"{bad json", capture_output=True, env=self.env, check=False
        )
        self.assertEqual(completed.returncode, 0)
        payload = json.loads(completed.stdout.decode("utf-8"))["hookSpecificOutput"]
        self.assertEqual(payload["permissionDecision"], "deny")
        self.assertEqual(payload["permissionDecisionReason"], policy.REASONS["policy-error"][1])

    def test_build_request_mapping(self) -> None:
        root, cwd = "/repo", "/repo/src"
        req = claude.build_request({"tool_name": "Bash", "tool_input": {"command": "ls"}}, root, cwd)
        self.assertEqual(req, {"version": 1, "root": root, "cwd": cwd, "operation": {"kind": "shell", "text": "ls"}})
        req = claude.build_request({"tool_name": "Edit", "tool_input": {"file_path": "a.gd"}}, root, cwd)
        self.assertEqual(req["operation"], {"kind": "write", "paths": ["a.gd"]})
        req = claude.build_request({"tool_name": "NotebookEdit", "tool_input": {"notebook_path": "n.ipynb"}}, root, cwd)
        self.assertEqual(req["operation"], {"kind": "write", "paths": ["n.ipynb"]})
        req = claude.build_request({"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "src"}}, root, cwd)
        self.assertEqual(req["operation"], {"kind": "read", "paths": ["src"]})
        self.assertIsNone(claude.build_request({"tool_name": "Task", "tool_input": {}}, root, cwd))
        self.assertIsNone(claude.build_request({"tool_name": "Bash", "tool_input": "ls"}, root, cwd))

    def test_root_resolution_prefers_project_dir(self) -> None:
        self.assertEqual(claude.resolve_root("/elsewhere", {"CLAUDE_PROJECT_DIR": self.root}), self.root)
        self.assertEqual(claude.resolve_root(self.root, {}), self.root)  # not a git repo: falls back to cwd


class StopTest(AdapterCase):
    def stop_event(self) -> dict:
        return {"hook_event_name": "Stop", "session_id": "s", "stop_hook_active": False, "cwd": self.root}

    def assert_never_blocks(self, out: str) -> None:
        if out:
            payload = json.loads(out)
            self.assertNotIn("decision", payload)
            self.assertNotIn("hookSpecificOutput", payload)

    def test_missing_gate_script_reports_unavailable(self) -> None:
        code, out = self.run_adapter(self.stop_event())
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(
            payload,
            {"systemMessage": "gate: unavailable — run tools/agent.sh check before claiming completion (ADR 0007 D20)"},
        )
        self.assert_never_blocks(out)

    def test_failing_gate_reports_its_status_line(self) -> None:
        self.write_gate("import sys\nprint('none')\nsys.exit(1)\n")
        code, out = self.run_adapter(self.stop_event())
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["systemMessage"], "none" + claude.STOP_ADVICE)
        self.assert_never_blocks(out)

    def test_stale_gate_reports_first_line_only(self) -> None:
        self.write_gate("import sys\nprint('stale')\nprint('details')\nsys.exit(3)\n")
        _, out = self.run_adapter(self.stop_event())
        self.assertEqual(json.loads(out)["systemMessage"], "stale" + claude.STOP_ADVICE)

    def test_passing_gate_is_silent(self) -> None:
        self.write_gate("print('current pass')\n")
        code, out = self.run_adapter(self.stop_event())
        self.assertEqual((code, out), (0, ""))

    def test_gate_receives_status_quiet_and_runs_in_root(self) -> None:
        self.write_gate("import os, sys\nprint(' '.join(sys.argv[1:]) + '|' + os.getcwd())\nsys.exit(1)\n")
        _, out = self.run_adapter(self.stop_event())
        message = json.loads(out)["systemMessage"]
        self.assertTrue(message.startswith("--status --quiet|"), message)
        self.assertEqual(os.path.realpath(message.split("|", 1)[1].split(" — ")[0]), self.root)

    def test_timeout_reports_unavailable(self) -> None:
        self.write_gate("import time\ntime.sleep(5)\n")
        with mock.patch.object(claude, "GATE_TIMEOUT_SECONDS", 0.2):
            self.assertEqual(claude.gate_status(self.root), claude.GATE_UNAVAILABLE)

    def test_crashing_gate_reports_unavailable(self) -> None:
        self.write_gate("raise SystemExit(4)\n")
        self.assertEqual(claude.gate_status(self.root), claude.GATE_UNAVAILABLE)

    def test_stop_hook_active_still_advisory(self) -> None:
        event = dict(self.stop_event(), stop_hook_active=True)
        stdout = io.StringIO()
        code = claude.main(stdin=io.BytesIO(json.dumps(event).encode("utf-8")), stdout=stdout, environ=self.env)
        self.assertEqual(code, 0)
        self.assert_never_blocks(stdout.getvalue())
        self.assertIn("systemMessage", stdout.getvalue())

    def test_unknown_event_is_silent(self) -> None:
        stdout = io.StringIO()
        event = {"hook_event_name": "SessionStart", "cwd": self.root}
        code = claude.main(stdin=io.BytesIO(json.dumps(event).encode("utf-8")), stdout=stdout, environ=self.env)
        self.assertEqual((code, stdout.getvalue()), (0, ""))


if __name__ == "__main__":
    unittest.main()
