# UI screens — 2026-10-29

Runtime evidence for the UI lane (`lane/ui`, based on `4af9b07`). Every PNG is the raw
320x180 viewport captured by `tools/playtest/capture_screens.tscn` under `xvfb-run`:

```
xvfb-run -a tools/godot.sh res://tools/playtest/capture_screens.tscn -- --output=/tmp/screens
```

Screens: title, menu, garage (engine + tires bought, integrity 64), options, options_controls,
select_car, select_track, lobby_connect, lobby_host (local preview: the net lane is pending),
hud (fake race fixture, seed 271029), pause, results (fake results array, seed 271029).
The profile and settings used by the capture are redirected to `user://capture-*`.
