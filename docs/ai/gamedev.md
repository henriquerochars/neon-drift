# Game verification

A passing gate proves the project imports, lints and its tests pass. It does not prove the
game looks or plays right. Anything a player sees or feels ships with runtime evidence:

- Screenshots or GIFs captured with `tools/playtest/capture_*.tscn` through `tools/godot.sh`
  (needs a display; `xvfb-run` works), converted with `tools/playtest/make_gifs.py`.
- Seeded race metrics from `tools/playtest/race_runs.tscn`: seed, track, car, finish
  time, position. Reports name their seed and commit.
- Taste (art direction, feel, fun) is the human's call. Agents propose with evidence.
