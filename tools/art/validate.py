#!/usr/bin/env python3
"""Validate the art tree: every PNG under art/ parses, has a committed .import sibling and
stays within the sprite size budget; art/LICENSE exists. Standard library only."""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "art"
MAX_SIDE = 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as handle:
        head = handle.read(24)
    if head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    return width, height


def main() -> int:
    problems: list[str] = []
    if not (ART / "LICENSE").is_file():
        problems.append("art/LICENSE is missing")
    for png in sorted(ART.rglob("*.png")):
        rel = png.relative_to(ROOT)
        try:
            width, height = png_size(png)
        except (OSError, ValueError) as exc:
            problems.append(f"{rel}: {exc}")
            continue
        if width > MAX_SIDE or height > MAX_SIDE:
            problems.append(f"{rel}: {width}x{height} exceeds {MAX_SIDE}px")
        if not png.with_name(png.name + ".import").is_file():
            problems.append(f"{rel}: missing .import (run tools/godot.sh --headless --import)")
    for problem in problems:
        print(f"art: {problem}")
    if problems:
        return 1
    print("art OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
