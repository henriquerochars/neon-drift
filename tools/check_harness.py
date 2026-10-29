#!/usr/bin/env python3
"""Check that the Neon Drift agent harness is wired consistently.

- every role in ROLES has a contract under ``.claude/agents/<role>.md`` with ``model: inherit``;
- ``.claude/settings.json`` routes ``PreToolUse`` and ``Stop`` through ``tools/agent_hooks/claude.py``;
- every entry in ``.claude/skills/`` is a relative symlink into ``.agents/skills/`` that resolves;
- ``AGENTS.md`` exists and ``CLAUDE.md`` imports it.

Standard library only. Exit 0 when consistent, 1 otherwise.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROLES = (
    "architect",
    "game-designer",
    "gameplay-dev",
    "net-engineer",
    "pixel-artist",
    "audio-designer",
    "qa-playtester",
    "release-engineer",
)
HOOK_COMMAND = "tools/agent_hooks/claude.py"


def _front_matter(text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end < 0:
        return {}
    result: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            result[key.strip()] = value.strip()
    return result


def check_roles(root: Path) -> list[str]:
    problems: list[str] = []
    for role in ROLES:
        path = root / ".claude" / "agents" / f"{role}.md"
        if not path.is_file():
            problems.append(f"missing role contract: {path.relative_to(root)}")
            continue
        meta = _front_matter(path.read_text(encoding="utf-8"))
        if meta.get("name") != role:
            problems.append(f"{path.relative_to(root)}: name must be {role!r}")
        if meta.get("model") != "inherit":
            problems.append(f"{path.relative_to(root)}: model must be 'inherit'")
        if not meta.get("description"):
            problems.append(f"{path.relative_to(root)}: description is required")
    return problems


def check_settings(root: Path) -> list[str]:
    path = root / ".claude" / "settings.json"
    if not path.is_file():
        return ["missing .claude/settings.json"]
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return [f".claude/settings.json is not valid JSON: {exc}"]
    hooks = settings.get("hooks", {})
    problems: list[str] = []
    for event in ("PreToolUse", "Stop"):
        entries = hooks.get(event, [])
        commands = [h.get("command", "") for e in entries for h in e.get("hooks", [])]
        if not any(HOOK_COMMAND in c for c in commands):
            problems.append(f".claude/settings.json: {event} must run {HOOK_COMMAND}")
    return problems


def check_skills(root: Path) -> list[str]:
    problems: list[str] = []
    skills = root / ".claude" / "skills"
    canonical = root / ".agents" / "skills"
    if not skills.is_dir():
        return []
    for entry in sorted(skills.iterdir()):
        if not entry.is_symlink():
            problems.append(f"{entry.relative_to(root)} must be a symlink into .agents/skills/")
            continue
        target = os.readlink(entry)
        if os.path.isabs(target):
            problems.append(f"{entry.relative_to(root)} must use a relative link")
        resolved = (entry.parent / target).resolve()
        if not resolved.is_dir() or canonical.resolve() not in resolved.parents:
            problems.append(f"{entry.relative_to(root)} does not resolve inside .agents/skills/")
        elif not (resolved / "SKILL.md").is_file():
            problems.append(f"{entry.relative_to(root)}: SKILL.md missing")
    return problems


def check_instructions(root: Path) -> list[str]:
    problems: list[str] = []
    if not (root / "AGENTS.md").is_file():
        problems.append("missing AGENTS.md")
    claude = root / "CLAUDE.md"
    if not claude.is_file():
        problems.append("missing CLAUDE.md")
    elif "@AGENTS.md" not in claude.read_text(encoding="utf-8"):
        problems.append("CLAUDE.md must import AGENTS.md with '@AGENTS.md'")
    return problems


def main() -> int:
    problems = check_instructions(ROOT) + check_roles(ROOT) + check_settings(ROOT) + check_skills(ROOT)
    for problem in problems:
        print(f"harness: {problem}")
    if problems:
        return 1
    print("harness OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
