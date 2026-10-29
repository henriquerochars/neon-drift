extends Node
## Runtime evidence: runs a race on a display with the local car driven by an AiDriver and
## saves a PNG of the 320x180 viewport every few ticks.
##   xvfb-run -a tools/godot.sh res://tools/playtest/capture_race.tscn -- \
##     --track=coast --seed=7 --output=/tmp/race-cap [--ticks=480] [--warmup=0] [--every=4]
## Prints QA_CAPTURE_REQUIRES_DISPLAY and exits 1 when the DisplayServer is headless.

const RACE_SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const DEFAULT_TRACK: String = "coast"
const DEFAULT_SEED: int = 7
const DEFAULT_TICKS: int = 480
const DEFAULT_EVERY: int = 4
const DEFAULT_WARMUP: int = 0
const DEFAULT_OUTPUT: String = "/tmp/race-cap"
const LOCAL_CAR: StringName = &"vortex"
const LOCAL_SKILL: float = 0.8
const AI_CARS: int = 7
const SKILL_MIN: float = 0.3
const SKILL_MAX: float = 1.0
const LOCAL_SEED_OFFSET: int = 99


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("QA_CAPTURE_REQUIRES_DISPLAY")
		get_tree().quit(1)
		return
	var args: Dictionary = PlaytestArgs.parse(OS.get_cmdline_user_args())
	var track_id: StringName = StringName(str(args.get("track", DEFAULT_TRACK)))
	var race_seed: int = int(args.get("seed", DEFAULT_SEED))
	var ticks: int = int(args.get("ticks", DEFAULT_TICKS))
	var every: int = maxi(int(args.get("every", DEFAULT_EVERY)), 1)
	var warmup: int = int(args.get("warmup", DEFAULT_WARMUP))
	var output: String = str(args.get("output", DEFAULT_OUTPUT))
	var track: TrackDef = Catalog.track(track_id)
	if track == null:
		printerr("capture_race: unknown track %s" % track_id)
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var config: RaceConfig = PlaytestArgs.ai_config(track, race_seed, AI_CARS, SKILL_MIN, SKILL_MAX)
	config.add_participant(AI_CARS, "YOU", LOCAL_CAR, RaceConfig.KIND_LOCAL, 0)
	var scene: RaceScene = RACE_SCENE.instantiate()
	scene.set_physics_process(false)
	add_child(scene)
	scene.start(config)
	var driver: AiDriver = AiDriver.new()
	driver.setup(scene.track_model, LOCAL_SKILL, race_seed + LOCAL_SEED_OFFSET, AI_CARS)
	scene.set_local_input_source(driver)
	var delta: float = 1.0 / Balance.value(&"fps_reference")
	for _tick: int in range(warmup):
		scene.step_tick(delta)
	var saved: int = 0
	for tick: int in range(ticks):
		scene.step_tick(delta)
		scene.refresh_view()
		if tick % every != 0:
			continue
		await RenderingServer.frame_post_draw
		var image: Image = get_viewport().get_texture().get_image()
		var path: String = "%s/frame_%04d.png" % [output, tick]
		if image.save_png(path) == OK:
			saved += 1
	print("QA_CAPTURE_DONE frames=%d output=%s" % [saved, output])
	get_tree().quit(0)
