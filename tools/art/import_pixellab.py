#!/usr/bin/env python3
"""Download PixelLab assets listed in art/source/pixellab/manifest.json into art/.

    python3 tools/art/import_pixellab.py [--only NAME ...] [--force]

Manifest entries: {"name": str, "url": str, "dest": "art/...png", "kind": str, "job": str,
"prompt": str}. Existing files are kept unless --force. Standard library only; the download
URLs returned by the PixelLab MCP need no auth. Provenance (job id, prompt, URL, sha256)
is written to art/source/pixellab/provenance.json.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "art" / "source" / "pixellab" / "manifest.json"
PROVENANCE = ROOT / "art" / "source" / "pixellab" / "provenance.json"
TIMEOUT = 60


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "neon-drift-import/1"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 - https only
        return response.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="*", default=None)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    entries = json.loads(MANIFEST.read_text(encoding="utf-8"))
    provenance: dict[str, dict] = {}
    if PROVENANCE.is_file():
        provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
    failures = 0
    for entry in entries:
        name = entry["name"]
        if args.only is not None and name not in args.only:
            continue
        dest = ROOT / entry["dest"]
        if dest.is_file() and not args.force:
            print(f"keep   {entry['dest']}")
            continue
        if not entry["url"].startswith("https://"):
            print(f"skip   {name}: url must be https")
            failures += 1
            continue
        try:
            data = fetch(entry["url"])
        except OSError as exc:
            print(f"FAIL   {name}: {exc}")
            failures += 1
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        provenance[name] = {
            "dest": entry["dest"],
            "kind": entry.get("kind", ""),
            "job": entry.get("job", ""),
            "prompt": entry.get("prompt", ""),
            "url": entry["url"],
            "sha256": hashlib.sha256(data).hexdigest(),
            "tool": "pixellab-mcp",
        }
        print(f"saved  {entry['dest']} ({len(data)} bytes)")
    PROVENANCE.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
