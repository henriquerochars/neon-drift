#!/usr/bin/env bash
# Regenerate the README media in docs/media/ from the real game (App scene, HUD, VFX).
# Needs a display or xvfb-run, ffmpeg and the pinned engine (tools/godot.sh).
#   tools/playtest/readme_media.sh            # capture + build into docs/media/
#   KEEP_FRAMES=1 tools/playtest/readme_media.sh   # keep the raw PNG frames in $WORK
# Clip choices (track, car, seed, nitro/jump ticks) come from capture_showcase --mode=scan.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/neon-drift-media.XXXXXX")}
RUN=()
if [ -z "${DISPLAY:-}" ] || [ "${USE_XVFB:-1}" = "1" ]; then
  RUN=(xvfb-run -a -s "-screen 0 1280x720x24")
fi
SHOWCASE=res://tools/playtest/capture_showcase.tscn

capture() { # capture <name> <args...>
  local name=$1; shift
  rm -rf "${WORK:?}/$name"
  "${RUN[@]}" tools/godot.sh --audio-driver Dummy --fixed-fps 30 "$SHOWCASE" -- \
    --output="$WORK/$name" "$@" 2>&1 | grep -E "SHOWCASE_DONE|SCRIPT ERROR" || true
  [ -f "$WORK/$name/frame_0000.png" ] || { echo "capture $name produced no frames" >&2; exit 1; }
}

echo "== captures into $WORK"
capture coast --mode=race --track=coast --car=vortex --paint=0 --seed=7 \
  --start=60 --frames=260 --nitro=200 --jump=420
capture desert --mode=race --track=desert_night --car=mirage --paint=3 --seed=3 \
  --start=75 --frames=160 --nitro=470 --jump=368
capture sunset --mode=race --track=sunset_city --car=phantom --paint=6 --seed=11 \
  --start=100 --frames=210 --nitro=180 --jump=417
capture garage --mode=garage --frames=362
capture title --mode=title --frames=92
rm -rf "${WORK:?}/screens"
"${RUN[@]}" tools/godot.sh --audio-driver Dummy res://tools/playtest/capture_screens.tscn -- \
  --output="$WORK/screens" >/dev/null 2>&1 || true
[ -f "$WORK/screens/menu.png" ] || { echo "screen capture failed" >&2; exit 1; }

echo "== build docs/media"
python3 tools/playtest/build_readme_media.py "$WORK" docs/media \
  --revision "$(git rev-parse --short HEAD)"
[ "${KEEP_FRAMES:-0}" = "1" ] || rm -rf "${WORK:?}"
