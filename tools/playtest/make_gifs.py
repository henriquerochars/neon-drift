"""Build a looping 15 fps GIF and middle PNG from every-four-tick captures."""
import argparse
from pathlib import Path
import shutil
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    frames = sorted(args.directory.glob("frame_*.png"))
    if not frames:
        parser.error("No captured frames")
    subprocess.run([
        "ffmpeg", "-y", "-threads", "1", "-filter_complex_threads", "1",
        "-framerate", "15", "-pattern_type", "glob", "-i",
        str(args.directory / "frame_*.png"), "-filter_complex",
        "split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0",
        str(args.directory / "race.gif"),
    ], check=True, timeout=120)
    shutil.copyfile(frames[len(frames) // 2], args.directory / "mid-race.png")


if __name__ == "__main__":
    main()
