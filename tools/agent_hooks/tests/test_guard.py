"""Tests for the guard CLI: request parsing, exit codes, fail-closed behaviour."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TOOLS_DIR))

from agent_hooks import guard, policy  # noqa: E402

GUARD = TOOLS_DIR / "agent_hooks" / "guard.py"
AGENT_SH = TOOLS_DIR / "agent.sh"
UNIQUE = "ZZ-request-marker-7f3a-ZZ"


class GuardCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.realpath(self.tmp.name)
        self.env = dict(os.environ, HOME="/home/guard-test-user")
        self.env.pop("TMPDIR", None)

    def run_guard(self, raw: bytes, command: list[str] = None) -> tuple[int, dict]:  # type: ignore[assignment]
        argv = command or [sys.executable, str(GUARD)]
        completed = subprocess.run(argv, input=raw, capture_output=True, env=self.env, cwd=self.root, check=False)
        self.assertTrue(completed.stdout, msg=completed.stderr.decode(errors="replace"))
        response = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual(response["version"], 1)
        return completed.returncode, response

    def request(self, text: str) -> bytes:
        return json.dumps(
            {"version": 1, "root": self.root, "cwd": self.root, "operation": {"kind": "shell", "text": text}}
        ).encode("utf-8")

    def test_exit_codes_per_decision(self) -> None:
        code, response = self.run_guard(self.request("git status"))
        self.assertEqual((code, response["decision"], response["reason"]), (0, "allow", "safe"))
        code, response = self.run_guard(self.request("git reset --hard"))
        self.assertEqual((code, response["decision"], response["reason"]), (1, "deny", "destructive-command"))
        code, response = self.run_guard(self.request("git push --tags"))
        self.assertEqual((code, response["decision"], response["reason"]), (2, "approval-required", "publication"))

    def test_malformed_json_exit_3(self) -> None:
        code, response = self.run_guard(b"{not json")
        self.assertEqual((code, response["decision"], response["reason"]), (3, "deny", "invalid-request"))

    def test_non_object_and_non_utf8_exit_3(self) -> None:
        code, response = self.run_guard(b"[1, 2]")
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))
        code, response = self.run_guard(b"\xff\xfe{}")
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))
        code, response = self.run_guard(b"")
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))

    def test_duplicate_keys_exit_3(self) -> None:
        raw = (
            '{"version": 1, "root": "%s", "cwd": "%s", '
            '"operation": {"kind": "shell", "text": "ls"}, "operation": {"kind": "shell", "text": "git push"}}'
            % (self.root, self.root)
        ).encode("utf-8")
        code, response = self.run_guard(raw)
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))

    def test_unknown_version_and_kind_exit_3(self) -> None:
        raw = json.dumps({"version": 2, "root": self.root, "cwd": self.root, "operation": {"kind": "shell", "text": "ls"}})
        code, response = self.run_guard(raw.encode("utf-8"))
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))
        raw = json.dumps({"version": 1, "root": self.root, "cwd": self.root, "operation": {"kind": "spell", "text": "ls"}})
        code, response = self.run_guard(raw.encode("utf-8"))
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))

    def test_oversized_request_exit_3(self) -> None:
        padding = "x" * (guard.MAX_REQUEST_BYTES + 10)
        raw = json.dumps({"version": 1, "root": self.root, "cwd": self.root, "operation": {"kind": "shell", "text": padding}})
        code, response = self.run_guard(raw.encode("utf-8"))
        self.assertEqual((code, response["reason"]), (3, "invalid-request"))

    def test_messages_never_echo_request(self) -> None:
        for text in ("git push --tags " + UNIQUE, "rm -rf src " + UNIQUE, "cat " + UNIQUE + ".keystore", "echo '" + UNIQUE):
            code, response = self.run_guard(self.request(text))
            self.assertNotIn(UNIQUE, json.dumps(response))
            self.assertNotEqual(code, 0)
        for reason, (_, message) in policy.REASONS.items():
            self.assertNotIn("{", message, msg=reason)

    def test_injected_evaluator_exception_exit_4(self) -> None:
        def broken(_: dict) -> policy.Decision:
            raise RuntimeError("boom " + UNIQUE)

        stdout = io.StringIO()
        code = guard.main(stdin=io.BytesIO(self.request("ls")), stdout=stdout, evaluator=broken)
        response = json.loads(stdout.getvalue())
        self.assertEqual(code, 4)
        self.assertEqual((response["decision"], response["reason"]), ("deny", "policy-error"))
        self.assertNotIn(UNIQUE, stdout.getvalue())

    def test_evaluator_returning_garbage_exit_4(self) -> None:
        stdout = io.StringIO()
        code = guard.main(stdin=io.BytesIO(self.request("ls")), stdout=stdout, evaluator=lambda _: "allow")  # type: ignore[arg-type,return-value]
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(stdout.getvalue())["reason"], "policy-error")

    def test_response_has_exactly_the_contract_keys(self) -> None:
        _, response = self.run_guard(self.request("ls"))
        self.assertEqual(set(response), {"version", "decision", "reason", "message"})

    @unittest.skipUnless(AGENT_SH.is_file(), "tools/agent.sh missing")
    def test_dispatcher_guard_command(self) -> None:
        env = dict(self.env, NEONDRIFT_PYTHON=sys.executable)
        completed = subprocess.run(
            ["sh", str(AGENT_SH), "guard"], input=self.request("git stash pop"), capture_output=True, env=env, check=False
        )
        self.assertEqual(completed.returncode, 1, completed.stderr.decode(errors="replace"))
        self.assertEqual(json.loads(completed.stdout.decode("utf-8"))["reason"], "shared-stash")
        completed = subprocess.run(["sh", str(AGENT_SH), "guard", "extra"], input=b"{}", capture_output=True, env=env, check=False)
        self.assertEqual(completed.returncode, 2)


if __name__ == "__main__":
    unittest.main()
