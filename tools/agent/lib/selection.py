"""Changed-scope check selection (ADR 0007 D12, docs/ai/contracts.md "Selection").

Pure functions over repository-relative POSIX paths. ``select_checks`` applies the D12
table: each path is classified by the first matching row, the union of the rows' checks
is returned in ``CHECK_ORDER``.
"""

from __future__ import annotations

import fnmatch
from typing import Iterable

CHECK_ORDER: tuple[str, ...] = (
    "harness",
    "record",
    "toolchain",
    "lint",
    "balance",
    "art",
    "godot-tests",
)
ALL_CHECKS: frozenset[str] = frozenset(CHECK_ORDER)
CODE_CHECKS: frozenset[str] = frozenset(("lint", "godot-tests"))
RECORD_CHECKS: frozenset[str] = frozenset(("record",))

# Working-tree noise that never counts as a change (contract "Gate").
IGNORED_DIRS: tuple[str, ...] = (
    ".godot",
    ".neondrift",
    ".tools",
    ".venv",
    "artifacts",
    "build",
    "reports",
)
IGNORED_SUFFIXES: tuple[str, ...] = (".log",)
IGNORED_NAMES: tuple[str, ...] = (".DS_Store",)

# Root agent instruction files that are harness policy, not documentation.
HARNESS_FILES: tuple[str, ...] = ("AGENTS.md", "CLAUDE.md", "docs/AGENTS.md", "tools/check_harness.py")
HARNESS_DIRS: tuple[str, ...] = ("tools/agent", "tools/agent_hooks", ".claude", ".grok", ".agents")
TOOLCHAIN_DIRS: tuple[str, ...] = (".github", "addons", "tools/playtest", "tools/data")
TOOLCHAIN_FILES: tuple[str, ...] = ("export_presets.cfg",)
ART_DIRS: tuple[str, ...] = ("art", "tools/art")
CODE_DIRS: tuple[str, ...] = ("src", "tests", "data")
CODE_SUFFIXES: tuple[str, ...] = (".gd", ".tscn", ".tres", ".gdshader")
CODE_FILES: tuple[str, ...] = ("project.godot",)
DOC_GLOBS: tuple[str, ...] = ("*.md", "LICENSE*", "CHANGELOG*")

# The project record (AGENTS.md "Work and verification"): what exists, where, in what state.
RECORD_FILE = "docs/STATUS.md"
RECORD_SOURCE_DIRS: tuple[str, ...] = ("src", "data")
RECORD_EXEMPT_DIRS: tuple[str, ...] = ("data/balance",)


def normalize_path(path: str) -> str:
    """Strip ``./`` prefixes and trailing slashes so rule matching is uniform."""
    text = path.replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    return text.strip("/")


def _in_dir(path: str, directory: str) -> bool:
    return path == directory or path.startswith(directory + "/")


def _basename(path: str) -> str:
    return path.rsplit("/", 1)[-1]


def is_relevant(path: str) -> bool:
    """False for paths the gate ignores (caches, state, logs, OS noise)."""
    text = normalize_path(path)
    if not text:
        return False
    if any(_in_dir(text, directory) for directory in IGNORED_DIRS):
        return False
    if text.endswith(IGNORED_SUFFIXES):
        return False
    return _basename(text) not in IGNORED_NAMES


def filter_relevant(paths: Iterable[str]) -> list[str]:
    """Normalised, de-duplicated, sorted relevant paths."""
    return sorted({normalize_path(path) for path in paths if is_relevant(path)})


def checks_for_path(path: str) -> frozenset[str]:
    """Checks required by one changed path, by the first matching D12 row."""
    text = normalize_path(path)
    if not is_relevant(text):
        return frozenset()
    if text in HARNESS_FILES or any(_in_dir(text, d) for d in HARNESS_DIRS):
        return frozenset(("harness",))
    if _in_dir(text, "docs"):
        return RECORD_CHECKS
    name = _basename(text)
    if any(fnmatch.fnmatchcase(name, glob) for glob in DOC_GLOBS):
        return frozenset()
    if (
        text in TOOLCHAIN_FILES
        or any(_in_dir(text, d) for d in TOOLCHAIN_DIRS)
        or (text.startswith("tools/") and text.count("/") == 1 and text.endswith(".sh"))
    ):
        return ALL_CHECKS
    if text.startswith("data/balance/") and text.endswith(".csv"):
        return CODE_CHECKS | {"balance"}
    if any(_in_dir(text, d) for d in ART_DIRS):
        return CODE_CHECKS | {"art"}
    if (
        text in CODE_FILES
        or any(_in_dir(text, d) for d in CODE_DIRS)
        or text.endswith(CODE_SUFFIXES)
    ):
        return CODE_CHECKS
    return ALL_CHECKS


def select_checks(paths: Iterable[str]) -> list[str]:
    """Union of the checks of every path, ordered by ``CHECK_ORDER``."""
    selected: set[str] = set()
    for path in paths:
        selected |= checks_for_path(path)
    return [check for check in CHECK_ORDER if check in selected]


def record_advisory(paths: Iterable[str]) -> str | None:
    """Reminder when source or content changed but the project record did not.

    Advisory only: it never selects a check or fails the gate. Balance values are tuning,
    not new content, so they do not ask for a record update.
    """
    changed = [normalize_path(path) for path in paths if is_relevant(path)]
    if RECORD_FILE in changed:
        return None
    touched = [
        path
        for path in changed
        if any(_in_dir(path, d) for d in RECORD_SOURCE_DIRS)
        and not any(_in_dir(path, d) for d in RECORD_EXEMPT_DIRS)
    ]
    if not touched:
        return None
    return (
        f"record: {len(touched)} file(s) under src/ or data/ changed but {RECORD_FILE} did not; "
        "update its feature map or in-flight entry before calling the PR ready (AGENTS.md)"
    )
