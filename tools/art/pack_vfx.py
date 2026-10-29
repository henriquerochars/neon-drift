#!/usr/bin/env python3
"""Pack a PixelLab vfx_workbench export (Aseprite-style sheet + JSON) into a uniform horizontal
strip plus the small JSON the race scene reads (docs/ARCHITECTURE.md "Race scene contract").

    python3 tools/art/pack_vfx.py <export.json> <export.png> <name> [--loop] [--rotate-cw]

Writes art/vfx/<name>.png and art/vfx/<name>.json. Uses ffmpeg (crop + hstack), standard
library otherwise.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "art" / "vfx"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_path", type=Path)
    parser.add_argument("png_path", type=Path)
    parser.add_argument("name")
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--rotate-cw", action="store_true", help="rotate frames 90 degrees clockwise")
    args = parser.parse_args()
    data = json.loads(args.json_path.read_text(encoding="utf-8"))
    frames = data["frames"]
    if not frames:
        print("no frames", file=sys.stderr)
        return 1
    width = int(frames[0]["frame"]["w"])
    height = int(frames[0]["frame"]["h"])
    pivot = frames[0].get("pivot", {"x": 0.5, "y": 0.5})
    duration_ms = int(frames[0].get("duration", 83))
    fps = round(1000.0 / max(duration_ms, 1))
    parts: list[str] = []
    labels: list[str] = []
    for index, frame in enumerate(frames):
        box = frame["frame"]
        chain = f"[0:v]crop={box['w']}:{box['h']}:{box['x']}:{box['y']}"
        if args.rotate_cw:
            chain += ",transpose=1"
        parts.append(f"{chain}[f{index}]")
        labels.append(f"[f{index}]")
    graph = ";".join(parts) + ";" + "".join(labels) + f"hstack=inputs={len(frames)}[out]"
    if len(frames) == 1:
        graph = parts[0].replace("[f0]", "[out]")
    OUT.mkdir(parents=True, exist_ok=True)
    out_png = OUT / f"{args.name}.png"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(args.png_path), "-filter_complex", graph, "-map", "[out]", str(out_png)],
        check=True,
    )
    frame_width, frame_height = (height, width) if args.rotate_cw else (width, height)
    pivot_x, pivot_y = (1.0 - float(pivot["y"]), float(pivot["x"])) if args.rotate_cw else (float(pivot["x"]), float(pivot["y"]))
    meta = {
        "frame_width": frame_width,
        "frame_height": frame_height,
        "frames": len(frames),
        "fps": fps,
        "loop": bool(args.loop),
        "pivot_x": round(pivot_x, 4),
        "pivot_y": round(pivot_y, 4),
        "source": "pixellab vfx_workbench",
    }
    (OUT / f"{args.name}.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"{out_png.relative_to(ROOT)}: {len(frames)} frames {frame_width}x{frame_height} @ {fps} fps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
