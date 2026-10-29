#!/usr/bin/env python3
"""Claude Code adapter for the shared guard (ADR 0007 D15, D20; docs/ai/contracts.md).

Handles the ``PreToolUse`` and ``Stop`` hook events. The hook JSON arrives on stdin.

- ``PreToolUse``: maps the tool call to a guard request and prints a
  ``hookSpecificOutput`` with ``permissionDecision`` ``deny`` or ``ask``. ``allow`` prints
  nothing so the native permission system still applies. Any adapter error denies.
- ``Stop``: runs the changed-scope gate in ``--status --quiet`` mode and, when the receipt
  is not a current pass (or the gate is unavailable), prints an advisory ``systemMessage``.
  It never blocks.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import BinaryIO, Mapping, Optional, TextIO

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_hooks import guard, policy  # noqa: E402

READ_TOOLS = {"Read": "file_path", "Grep": "path", "Glob": "path"}
WRITE_TOOLS = {"Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}
GATE_SCRIPT = os.path.join("tools", "agent", "check_changed.py")
GATE_TIMEOUT_SECONDS = 20
GIT_TIMEOUT_SECONDS = 5
GATE_UNAVAILABLE = "gate: unavailable"
STOP_ADVICE = " — run tools/agent.sh check before claiming completion (ADR 0007 D20)"


def resolve_root(cwd: str, environ: Mapping[str, str]) -> str:
    configured = environ.get("CLAUDE_PROJECT_DIR", "")
    if configured:
        return os.path.abspath(configured)
    try:
        completed = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
        top = completed.stdout.strip()
        if completed.returncode == 0 and top:
            return top
    except (OSError, subprocess.SubprocessError):
        pass
    return cwd


def build_request(event: Mapping[str, object], root: str, cwd: str) -> Optional[dict]:
    """Map a PreToolUse event to a guard request; None means the tool is not guarded."""
    tool = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        return None
    operation: dict[str, object]
    if tool == "Bash":
        operation = {"kind": "shell", "text": tool_input.get("command", "")}
    elif tool in READ_TOOLS:
        path = tool_input.get(READ_TOOLS[tool])
        if not path:
            return None
        operation = {"kind": "read", "paths": [path]}
    elif tool in WRITE_TOOLS:
        operation = {"kind": "write", "paths": [tool_input.get(WRITE_TOOLS[tool])]}
    else:
        return None
    return {"version": policy.REQUEST_VERSION, "root": root, "cwd": cwd, "operation": operation}


def _pre_tool_output(permission: str, message: str) -> dict:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": permission,
            "permissionDecisionReason": message,
        }
    }


def _deny_output(reason: str) -> dict:
    return _pre_tool_output("deny", policy.decision_for(reason).message)


def pre_tool_use(event: Mapping[str, object], environ: Mapping[str, str]) -> Optional[dict]:
    cwd = event.get("cwd")
    cwd = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    request = build_request(event, resolve_root(cwd, environ), cwd)
    if request is None:
        return None
    decision = policy.evaluate(request)
    if decision.decision == policy.ALLOW:
        return None
    permission = "deny" if decision.decision == policy.DENY else "ask"
    return _pre_tool_output(permission, decision.message)


def gate_status(root: str) -> Optional[str]:
    """Return None for a current passing gate, else the one-line status to report."""
    script = os.path.join(root, GATE_SCRIPT)
    if not os.path.isfile(script):
        return GATE_UNAVAILABLE
    try:
        completed = subprocess.run(
            [sys.executable, script, "--status", "--quiet"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=GATE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return GATE_UNAVAILABLE
    if completed.returncode == 0:
        return None
    line = completed.stdout.strip().splitlines()
    return line[0].strip() if line and line[0].strip() else GATE_UNAVAILABLE


def stop(event: Mapping[str, object], environ: Mapping[str, str]) -> Optional[dict]:
    cwd = event.get("cwd")
    cwd = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    status = gate_status(resolve_root(cwd, environ))
    if status is None:
        return None
    return {"systemMessage": status + STOP_ADVICE}


def main(
    stdin: Optional[BinaryIO] = None,
    stdout: Optional[TextIO] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> int:
    stdin = stdin if stdin is not None else sys.stdin.buffer
    stdout = stdout if stdout is not None else sys.stdout
    environ = environ if environ is not None else os.environ
    output: Optional[dict]
    try:
        event = guard.load_request(stdin.read(guard.MAX_REQUEST_BYTES + 1))
        name = event.get("hook_event_name")
        if name == "PreToolUse":
            output = pre_tool_use(event, environ)
        elif name == "Stop":
            try:
                output = stop(event, environ)
            except Exception:  # noqa: BLE001 - Stop is advisory and never blocks
                output = {"systemMessage": GATE_UNAVAILABLE + STOP_ADVICE}
        else:
            output = None
    except Exception:  # noqa: BLE001 - adapter errors deny
        output = _deny_output("policy-error")
    if output is not None:
        stdout.write(json.dumps(output) + "\n")
        stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
