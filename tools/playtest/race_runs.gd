extends Node
## Headless batch race: all-AI participants driven through RaceScene.step_tick as fast as
## possible. Prints one JSON line and optionally writes it to --output.
##   tools/godot.sh --headless res://tools/playtest/race_runs.tscn -- \
##     --track=coast --seed=1 --cars=8 --ticks=18000 --output=/tmp/race.json

const RACE_SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const DEFAULT_TRACK: String = "coast"
const DEFAULT_SEED: int = 1
const DEFAULT_CARS: int = 8
const DEFAULT_TICKS: int = 18000
const SKILL_MIN: float = 0.3
const SKILL_MAX: float = 1.0


func _ready() -> void:
	var args: Dictionary = PlaytestArgs.parse(OS.get_cmdline_user_args())
	var track_id: StringName = StringName(str(args.get("track", DEFAULT_TRACK)))
	var race_seed: int = int(args.get("seed", DEFAULT_SEED))
	var cars: int = clampi(int(args.get("cars", DEFAULT_CARS)), 1, Constants.MAX_PLAYERS)
	var max_ticks: int = int(args.get("ticks", DEFAULT_TICKS))
	var track: TrackDef = Catalog.track(track_id)
	if track == null:
		printerr("race_runs: unknown track %s" % track_id)
		get_tree().quit(2)
		return
	var config: RaceConfig = PlaytestArgs.ai_config(track, race_seed, cars, SKILL_MIN, SKILL_MAX)
	var scene: RaceScene = RACE_SCENE.instantiate()
	scene.set_physics_process(false)
	add_child(scene)
	scene.start(config)
	var delta: float = 1.0 / Balance.value(&"fps_reference")
	var ticks: int = 0
	for _tick: int in range(max_ticks):
		scene.step_tick(delta)
		ticks += 1
		if scene.phase == Constants.PHASE_FINISHED:
			break
	var metrics: Dictionary = scene.metrics()
	var line: Dictionary = {
		"track": str(track_id),
		"seed": race_seed,
		"results": scene.results(),
		"ticks": ticks,
		"finished": scene.phase == Constants.PHASE_FINISHED,
		"max_offroad_ticks": int(metrics["max_offroad_ticks"]),
		"crushes": int(metrics["crushes"]),
		"bumps": int(metrics["bumps"]),
		"scenery_hits": int(metrics["scenery_hits"]),
	}
	var text: String = JSON.stringify(line)
	print(text)
	var output: String = str(args.get("output", ""))
	if not output.is_empty():
		var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
		if file != null:
			file.store_line(text)
	get_tree().quit(0 if bool(line["finished"]) else 1)
