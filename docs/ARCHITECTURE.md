# Architecture

Layer graph (enforced by `tools/check_layers.py`): `gameplay -> net -> core`,
`gameplay -> data -> core`, `ui -> gameplay`, `audio -> core`. No cycles.

```
src/core/      RaceBus (autoload signals), GameSettings (autoload), PlayerProfile (autoload),
               DriverInput, CarState, CarStats, Constants
src/data/      CarDef, PartDef, TrackDef, TrackSegment, Balance (CSV loader), Catalog
src/gameplay/  input/ (DriverInputSource + LocalDriverInputSource + ScriptedDriverInputSource)
               sim/   (CarSim, TrackModel: pure, deterministic, tested)
               road/  (PseudoRoad renderer, SpriteLayer)
               race/  (RaceScene, RaceManager, Participant, HUD data)
               ai/    (AiDriver: DriverInputSource driven by TrackModel look-ahead)
src/net/       NetSession (autoload), RaceSync, Lobby model
src/ui/        app/ (App main scene + ScreenRouter), title/, menu/, options/, garage/,
               select/, lobby/, hud/, results/, pause/
src/audio/     AudioDirector (autoload), SfxBank
data/          cars/, parts/, tracks/ (.tres), balance/physics.csv
art/           PixelLab PNGs (+ .import), palette, LICENSE (CC-BY 4.0)
audio/         generated OGG (tools/audio/gen_audio.py), manifest.json
```

## Simulation model
`CarSim.step(state, input, stats, track, delta)` is a pure function over `CarState`
(position along the track `z`, lateral `x` in [-1, 1] road halves, `speed`, `altitude`,
`vertical_speed`, `nitro`, `thrusters`, `integrity`, flags). The race scene runs it at
the physics tick for every participant; the network layer replicates `CarState` of
remote peers and interpolates. Determinism matters for AI and tests, not for lockstep.

## Rendering
`PseudoRoad` draws `TrackModel` segments from the camera position: per segment project
(x, y, z) with `camera_depth`, draw grass/rumble/road/lane quads back to front, then
roadside sprites and cars sorted by depth, scaled by projection. 320x180 canvas.

## Networking (`docs/NET_API.md`)
`NetSession` (autoload, `src/net/`) owns the ENet peer. Each peer has authority over its
own `CarState`; the host (peer 1) owns race phase, clock, finish order and crush verdicts.
Clients report landings to the host; the host validates (altitude, overlap) and broadcasts.

## Autoloads (declared by architect)
`RaceBus`, `GameSettings`, `PlayerProfile`, `NetSession`, `AudioDirector`.

## Race scene contract (shared by the race, UI and net lanes)
`RaceScene` (`src/gameplay/race/race_scene.tscn`, script `race_scene.gd`, `class_name RaceScene`):
- `start(config: RaceConfig) -> void` — builds TrackModel, participants, countdown, then racing.
- `phase: StringName` (Constants.PHASE_*), `race_time: float`, `track_model: TrackModel`,
  `config: RaceConfig`.
- `state_of(participant_id: int) -> CarState`, `stats_of(id) -> CarStats`,
  `place_of(id) -> int` (1-based), `lap_of(id) -> int`, `local_id() -> int`,
  `standings() -> Array[int]` (participant ids, leader first).
- `set_local_input_source(source: DriverInputSource)` — the UI/pause layer may swap it.
- `pause(paused: bool)`.
- Online hooks (duck-typed by `RaceSync`): `set_remote_state(id: int, packed: PackedFloat32Array)`,
  signal `local_state_updated(id: int, packed: PackedFloat32Array)` (every physics tick),
  `apply_penalty(id: int, kind: StringName, data: Dictionary)` with kinds `&"crush_victim"`, `&"crush_attacker"`,
  `&"bump"`, `&"scenery"`, signal `penalty_decided(id: int, kind: StringName, data: Dictionary)` (host only),
  `set_authority(is_host: bool)` (offline = true), `force_phase(phase: StringName, time: float)`,
  `force_finish(id: int, place: int, time: float)`, `force_results(results: Array[Dictionary])`.
  Countdown time is seconds remaining (`_countdown_left`); repeated countdown updates only
  resync that value. Repeated RACING updates do nothing. FINISHED arrives only with results.
  Predicted finishes do not block the first confirmed finish (place/time/event/local grace);
  only confirmed finishes deduplicate. Clients never finish through their local grace timer.
  Host crossings in a tick sort by interpolated crossing time, then participant id.
  Finished cars are excluded from contacts and coast with wrapped track coordinates.
  Bump data contains the signed `push` delta and `speed_ratio` decided by the host.
  Crush feedback emits `car_crushed(attacker, victim)` and hard `car_landed(attacker, true)`
  on clients without applying damage; only penalties apply damage.
- Emits every RaceBus race signal. `race_finished(results)` entries:
  `{"id": int, "name": String, "car_id": StringName, "place": int, "time": float,
  "earnings": int, "finished": bool}`.
- Reads VFX from `art/vfx/<name>.png` + `<name>.json`
  (`{"frame_width", "frame_height", "frames", "fps", "loop"}`); missing files are skipped.
  Names: `nitro_flame` (loop), `thruster_burst` (one-shot), `landing_dust` (one-shot),
  `crush_sparks` (one-shot), `bump_sparks` (one-shot).
