#!/usr/bin/env python3
"""Project record check (AGENTS.md "Work and verification", docs/ai/validation.md).

    python3 tools/agent/check_record.py [--root PATH]

Fails when the written record no longer maps the repository:

- every source area is named in ``docs/STATUS.md`` as a backticked ``src/.../`` path. The
  areas are each folder under ``src/gameplay/`` and ``src/ui/`` plus every other folder
  directly under ``src/`` (``core``, ``net``, ``data``);
- every top-level ``docs/*.md`` and every ``docs/`` subfolder is linked from
  ``docs/README.md``;
- every ADR under ``docs/adr/`` is linked from ``docs/adr/README.md``;
- every relative Markdown link in those indexes and in ``docs/STATUS.md`` resolves.

It reads the working tree only and never runs git or the engine. Exit 0 pass, 1 drift.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Sequence
from urllib.parse import unquote

STATUS_DOC = "docs/STATUS.md"
DOCS_INDEX = "docs/README.md"
ADR_INDEX = "docs/adr/README.md"
FEATURE_PARENTS: tuple[str, ...] = ("gameplay", "ui")
LINK_RE = re.compile(r"\[[^\]]*\]\((?:<([^>\n]+)>|([^)\s]+))(?:\s+\"[^\"]*\")?\)")
FENCE_RE = re.compile(r"^(```|~~~).*?^\1", re.MULTILINE | re.DOTALL)
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def _subdirs(path: Path) -> list[Path]:
    if not path.is_dir():
        return []
    return sorted(child for child in path.iterdir() if child.is_dir() and not child.name.startswith("."))


def source_areas(root: Path) -> list[str]:
    """Repository-relative ``src/<layer>/`` and ``src/<gameplay|ui>/<feature>/`` paths."""
    areas: list[str] = []
    for layer in _subdirs(root / "src"):
        if layer.name in FEATURE_PARENTS:
            areas.extend(f"src/{layer.name}/{feature.name}/" for feature in _subdirs(layer))
        else:
            areas.append(f"src/{layer.name}/")
    return areas


def local_links(text: str) -> list[str]:
    """Relative link targets outside fenced code, without fragments or external schemes."""
    targets: list[str] = []
    for match in LINK_RE.finditer(FENCE_RE.sub("", text)):
        target = match.group(1) or match.group(2)
        if target.startswith("#") or SCHEME_RE.match(target):
            continue
        target = unquote(target.split("#", 1)[0])
        if target:
            targets.append(target)
    return targets


def resolved_links(root: Path, document: str) -> tuple[set[Path], list[str]]:
    """Resolved local link targets of ``document`` and the targets that do not exist."""
    path = root / document
    resolved: set[Path] = set()
    broken: list[str] = []
    for target in local_links(path.read_text(encoding="utf-8")):
        destination = (path.parent / target).resolve()
        if destination.exists():
            resolved.add(destination)
        else:
            broken.append(target)
    return resolved, broken


def _covers(links: set[Path], target: Path) -> bool:
    """True when a link points at ``target`` or, for a folder, at anything inside it."""
    target = target.resolve()
    if target in links:
        return True
    return target.is_dir() and any(target in link.parents for link in links)


def check(root: Path) -> list[str]:
    """Every drift between the repository and its record, as actionable messages."""
    root = root.resolve()
    problems: list[str] = []
    for document in (STATUS_DOC, DOCS_INDEX, ADR_INDEX):
        if not (root / document).is_file():
            problems.append(f"{document} is missing")
    if problems:
        return problems

    status = (root / STATUS_DOC).read_text(encoding="utf-8")
    for area in source_areas(root):
        if f"`{area}`" not in status:
            problems.append(f"{STATUS_DOC} does not map the source area `{area}`")

    for document in (STATUS_DOC, DOCS_INDEX, ADR_INDEX):
        _, broken = resolved_links(root, document)
        problems.extend(f"{document} links to a missing path: {target}" for target in broken)

    index_links, _ = resolved_links(root, DOCS_INDEX)
    docs = root / "docs"
    for page in sorted(docs.glob("*.md")):
        if page.name != "README.md" and not _covers(index_links, page):
            problems.append(f"{DOCS_INDEX} does not link docs/{page.name}")
    for folder in _subdirs(docs):
        if not _covers(index_links, folder):
            problems.append(f"{DOCS_INDEX} does not link the folder docs/{folder.name}/")

    adr_links, _ = resolved_links(root, ADR_INDEX)
    for adr in sorted((docs / "adr").glob("*.md")):
        if adr.name != "README.md" and not _covers(adr_links, adr):
            problems.append(f"{ADR_INDEX} does not link docs/adr/{adr.name}")
    return problems


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools/agent/check_record.py",
        description="Fail when docs/STATUS.md and the docs indexes no longer map the repository.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository root (default: this checkout)",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)
    problems = check(args.root)
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        print(
            "Update docs/STATUS.md (where things are, what state they are in) or the docs "
            "index in the same change. See AGENTS.md, Work and verification."
        )
        return 1
    print(f"PASS: record maps {len(source_areas(args.root.resolve()))} source areas and the docs indexes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
