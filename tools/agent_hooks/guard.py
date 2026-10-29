#!/usr/bin/env python3
"""Shared guard CLI (ADR 0007 D09; docs/ai/contracts.md "Guard").

Reads one UTF-8 JSON request (at most 1 MiB) on stdin, writes one JSON response on
stdout. Exit codes: 0 allow, 1 deny, 2 approval-required, 3 invalid request, 4 internal
error. Every failure path denies; messages are fixed strings that never echo the request.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import BinaryIO, Callable, Optional, TextIO

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_hooks import policy  # noqa: E402

MAX_REQUEST_BYTES = 1024 * 1024
EXIT_ALLOW = 0
EXIT_DENY = 1
EXIT_APPROVAL = 2
EXIT_INVALID = 3
EXIT_INTERNAL = 4
EXIT_BY_DECISION = {policy.ALLOW: EXIT_ALLOW, policy.DENY: EXIT_DENY, policy.APPROVAL: EXIT_APPROVAL}
EXIT_BY_REASON = {"invalid-request": EXIT_INVALID, "policy-error": EXIT_INTERNAL}


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def load_request(raw: bytes) -> dict:
    """Parse request bytes strictly: size bound, UTF-8, one JSON object, no duplicate keys."""
    if len(raw) > MAX_REQUEST_BYTES:
        raise ValueError("request too large")
    request = json.loads(raw.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    if not isinstance(request, dict):
        raise ValueError("request is not a JSON object")
    return request


def exit_code_for(decision: policy.Decision) -> int:
    return EXIT_BY_REASON.get(decision.reason, EXIT_BY_DECISION[decision.decision])


def main(
    stdin: Optional[BinaryIO] = None,
    stdout: Optional[TextIO] = None,
    evaluator: Optional[Callable[[dict], policy.Decision]] = None,
) -> int:
    stdin = stdin if stdin is not None else sys.stdin.buffer
    stdout = stdout if stdout is not None else sys.stdout
    evaluate = evaluator if evaluator is not None else policy.evaluate
    try:
        request = load_request(stdin.read(MAX_REQUEST_BYTES + 1))
    except Exception:  # noqa: BLE001 - every parse failure denies
        decision = policy.INVALID
    else:
        try:
            decision = evaluate(request)
            if not isinstance(decision, policy.Decision) or decision.reason not in policy.REASONS:
                raise TypeError("evaluator returned no Decision")
        except Exception:  # noqa: BLE001 - internal errors deny
            decision = policy.decision_for("policy-error")
    stdout.write(json.dumps(decision.as_dict()) + "\n")
    stdout.flush()
    return exit_code_for(decision)


if __name__ == "__main__":
    sys.exit(main())
