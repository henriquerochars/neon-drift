#!/usr/bin/env python3
"""Build the README media from showcase captures (tools/playtest/readme_media.sh).

    python3 tools/playtest/build_readme_media.py <capture dir> <output dir> [--revision SHA]

Writes 2x nearest-neighbour GIFs (30 fps, looping, 128-colour palette), 2x screen PNGs, a car
line-up and a track strip, plus manifest.json with the revision and every file's size.
Standard library + ffmpeg only.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPS = 30
SCALE = 2
LINEUP_SCALE = 3
BACKGROUND = "0x14102a"
# clip name -> (output name, first frame); garage/title skip the frames before the UI draws.
CLIPS: dict[str, tuple[str, int]] = {
    "coast": ("gameplay-coast.gif", 0),
    "desert": ("gameplay-desert-night.gif", 0),
    "sunset": ("gameplay-sunset-city.gif", 0),
    "garage": ("garage.gif", 2),
    "title": ("title.gif", 2),
}
SCREENS: tuple[str, ...] = (
    "menu",
    "select_car",
    "select_track",
    "options",
    "lobby_host",
    "results",
)
CARS: tuple[str, ...] = ("vortex", "bruiser", "hornet", "phantom", "mirage")
TRACKS: tuple[str, ...] = ("bg_coast", "bg_sunset_city", "bg_desert_night")
MAX_GIF_BYTES = 6 * 1024 * 1024


def ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True, timeout=300)


def build_gif(frames: Path, start: int, output: Path) -> None:
    graph = (
        f"scale=iw*{SCALE}:ih*{SCALE}:flags=neighbor,split[a][b];"
        "[a]palettegen=max_colors=128:stats_mode=diff[p];"
        "[b][p]paletteuse=dither=none:diff_mode=rectangle"
    )
    ffmpeg(
        "-framerate", str(FPS), "-start_number", str(start),
        "-i", str(frames / "frame_%04d.png"), "-filter_complex", graph, "-loop", "0", str(output),
    )


def build_lineup(output: Path) -> None:
    inputs: list[str] = []
    for car in CARS:
        inputs += ["-i", str(ROOT / "art" / "cars" / car / "south-east.png")]
    pads = "".join(
        f"[{i}]pad=iw+16:ih+8:8:4:color={BACKGROUND}@0[c{i}];" for i in range(len(CARS))
    )
    stack = "".join(f"[c{i}]" for i in range(len(CARS)))
    graph = (
        f"{pads}{stack}hstack=inputs={len(CARS)},"
        f"scale=iw*{LINEUP_SCALE}:ih*{LINEUP_SCALE}:flags=neighbor"
    )
    ffmpeg(*inputs, "-filter_complex", graph, "-frames:v", "1", str(output))


def build_tracks(output: Path) -> None:
    inputs: list[str] = []
    for name in TRACKS:
        inputs += ["-i", str(ROOT / "art" / "backgrounds" / f"{name}.png")]
    graph = f"hstack=inputs={len(TRACKS)},scale=iw:ih:flags=neighbor"
    ffmpeg(*inputs, "-filter_complex", graph, "-frames:v", "1", str(output))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--revision", default="")
    args = parser.parse_args()
    if shutil.which("ffmpeg") is None:
        print("ffmpeg is required", file=sys.stderr)
        return 2
    out: Path = args.output
    (out / "screens").mkdir(parents=True, exist_ok=True)
    (out / ".gdignore").touch()
    files: list[Path] = []
    for clip, (name, start) in CLIPS.items():
        target = out / name
        build_gif(args.captures / clip, start, target)
        if target.stat().st_size > MAX_GIF_BYTES:
            print(f"{name} is larger than {MAX_GIF_BYTES} bytes", file=sys.stderr)
            return 1
        files.append(target)
    for screen in SCREENS:
        target = out / "screens" / f"{screen}.png"
        ffmpeg(
            "-i", str(args.captures / "screens" / f"{screen}.png"),
            "-vf", f"scale=iw*{SCALE}:ih*{SCALE}:flags=neighbor", str(target),
        )
        files.append(target)
    build_lineup(out / "cars.png")
    build_tracks(out / "tracks.png")
    files += [out / "cars.png", out / "tracks.png"]
    manifest = {
        "revision": args.revision,
        "generator": "tools/playtest/readme_media.sh",
        "files": {str(f.relative_to(out)): f.stat().st_size for f in files},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for path, size in manifest["files"].items():
        print(f"{size:>9}  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
