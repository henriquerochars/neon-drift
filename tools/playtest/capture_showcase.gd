extends Node
## README showcase captures of the real game (App main scene, HUD, VFX, audio director).
##
## Race clip, one PNG per rendered frame (run with a fixed frame rate so frame time is exact):
##   xvfb-run -a tools/godot.sh --audio-driver Dummy --fixed-fps 30 \
##     res://tools/playtest/capture_showcase.tscn -- --mode=race --track=coast --car=vortex \
##     --paint=0 --seed=7 --start=150 --frames=240 --nitro=300 --jump=420 --output=/tmp/clip
## --start is the first captured frame counted from the race launch (the countdown is 3 s);
## --nitro / --jump are comma-separated racing ticks (60 Hz, counted from GO).
##
## Garage clip: --mode=garage --frames=300 --output=...  (buys parts, cycles paint and cars).
## Title clip:  --mode=title --frames=90 --output=...
##
## Scan (headless, no frames): prints the local car's events per racing tick so a clip window
## can be chosen:
##   tools/godot.sh --headless res://tools/playtest/capture_showcase.tscn -- --mode=scan \
##     --track=coast --car=vortex --seed=7 --ticks=3600 --nitro=300 --jump=420

const APP: PackedScene = preload("res://src/ui/app/app.tscn")
const RACE_SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const PROFILE_PATH: String = "user://showcase-profile.json"
const SETTINGS_PATH: String = "user://showcase-settings.cfg"
const SKILL: float = 0.85
const DRIVER_SEED_OFFSET: int = 99
const SHOWCASE_MONEY: int = 99999
const GARAGE_STEP_FRAMES: int = 36
const SCAN_TICKS_DEFAULT: int = 3600
const MAX_COUNTDOWN_TICKS: int = 600
const PLAYER_NAME: String = "NEON"

var _args: Dictionary = {}
var _mode: String = "race"
var _output: String = "/tmp/neon-drift-showcase"
var _frame: int = 0
var _saved: int = 0
var _start: int = 0
var _frames: int = 0
var _app: App
var _garage_actions: Array[Callable] = []


func _ready() -> void:
	_args = PlaytestArgs.parse(OS.get_cmdline_user_args())
	_mode = str(_args.get("mode", "race"))
	_output = str(_args.get("output", _output))
	_start = int(_args.get("start", 0))
	_frames = int(_args.get("frames", 0))
	UiPaths.profile_path = PROFILE_PATH
	UiPaths.settings_path = SETTINGS_PATH
	PlayerProfile.reset()
	PlayerProfile.money = SHOWCASE_MONEY
	GameSettings.player_name = PLAYER_NAME
	set_process(false)
	_run.call_deferred()


func _run() -> void:
	if _mode == "scan":
		_scan()
		return
	if DisplayServer.get_name() == "headless":
		printerr("SHOWCASE_REQUIRES_DISPLAY")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_output)
	_app = APP.instantiate() as App
	add_child(_app)
	match _mode:
		"race":
			_start_race()
		"garage":
			_start_garage()
		_:
			_app.router.go(ScreenRouter.SCREEN_TITLE)
	set_process(true)


func _process(_delta: float) -> void:
	if _mode == "garage" and _frame % GARAGE_STEP_FRAMES == 0 and not _garage_actions.is_empty():
		var action: Callable = _garage_actions.pop_front()
		action.call()
	if _frame >= _start:
		var image: Image = get_viewport().get_texture().get_image()
		image.save_png("%s/frame_%04d.png" % [_output, _saved])
		_saved += 1
	_frame += 1
	if _saved >= _frames:
		print("SHOWCASE_DONE mode=%s frames=%d output=%s" % [_mode, _saved, _output])
		set_process(false)
		get_tree().quit()


func _start_race() -> void:
	var car: StringName = StringName(str(_args.get("car", "vortex")))
	PlayerProfile.selected_car = car
	PlayerProfile.set_paint(car, int(_args.get("paint", 0)))
	var select: SelectScreen = _app.router.go(ScreenRouter.SCREEN_SELECT) as SelectScreen
	select.confirm_button.pressed.emit()
	var track: StringName = StringName(str(_args.get("track", "coast")))
	for index: int in range(Catalog.tracks().size()):
		if Catalog.tracks()[index].id == track:
			select.track_index = index
	var race_seed: int = int(_args.get("seed", 7))
	_app.router.launcher.launch(_back_of_grid_config(car, track, race_seed))
	var host: RaceHost = _app.router.current as RaceHost
	var race: RaceScene = host.race as RaceScene
	race.set_local_input_source(_driver(race, race_seed))


func _driver(race: RaceScene, race_seed: int) -> ShowcaseDriver:
	var driver: ShowcaseDriver = ShowcaseDriver.new()
	driver.setup(race.track_model, SKILL, race_seed + DRIVER_SEED_OFFSET, race.local_id())
	driver.nitro_ticks = ShowcaseDriver.parse_ticks(str(_args.get("nitro", "")))
	driver.jump_ticks = ShowcaseDriver.parse_ticks(str(_args.get("jump", "")))
	return driver


func _start_garage() -> void:
	var garage: GarageScreen = _app.router.go(ScreenRouter.SCREEN_GARAGE) as GarageScreen
	_garage_actions = [
		func() -> void: garage.buy(&"engine"),
		func() -> void: garage.buy(&"turbo"),
		func() -> void: garage.cycle_paint(),
		func() -> void: garage.cycle_paint(),
		func() -> void: garage.buy(&"nitro_tank"),
		func() -> void: garage.next_car(),
		func() -> void: garage.buy(&"thrusters"),
		func() -> void: garage.cycle_paint(),
		func() -> void: garage.next_car(),
		func() -> void: garage.next_car(),
	]


func _scan() -> void:
	var race_seed: int = int(_args.get("seed", 7))
	var car: StringName = StringName(str(_args.get("car", "vortex")))
	PlayerProfile.selected_car = car
	var config: RaceConfig = _back_of_grid_config(
		car, StringName(str(_args.get("track", "coast"))), race_seed
	)
	var race: RaceScene = RACE_SCENE.instantiate() as RaceScene
	add_child(race)
	race.set_physics_process(false)
	race.start(config)
	race.set_local_input_source(_driver(race, race_seed))
	var delta: float = 1.0 / Balance.value(&"fps_reference")
	var guard: int = 0
	while race.phase == Constants.PHASE_COUNTDOWN and guard < MAX_COUNTDOWN_TICKS:
		race.step_tick(delta)
		guard += 1
	var local: int = race.local_id()
	var log: Array[String] = []
	var tick: Array[int] = [0]
	RaceBus.nitro_activated.connect(
		func(id: int) -> void: _note(log, tick[0], id == local, "nitro")
	)
	RaceBus.jump_started.connect(func(id: int) -> void: _note(log, tick[0], id == local, "jump"))
	RaceBus.car_crushed.connect(
		func(attacker: int, victim: int) -> void:
			_note(log, tick[0], attacker == local, "CRUSH_RIVAL")
			_note(log, tick[0], victim == local, "crushed_by_rival")
	)
	RaceBus.car_bumped.connect(func(id: int) -> void: _note(log, tick[0], id == local, "bump"))
	var place: int = race.place_of(local)
	for step: int in range(int(_args.get("ticks", SCAN_TICKS_DEFAULT))):
		tick[0] = step
		race.step_tick(delta)
		var now: int = race.place_of(local)
		if now != place:
			log.append("%d place %d->%d" % [step, place, now])
			place = now
		if race.phase == Constants.PHASE_FINISHED:
			break
	for line: String in log:
		print("SCAN ", line)
	print("SCAN_DONE place=%d" % race.place_of(local))
	race.queue_free()
	get_tree().quit()


## The solo config with the local car moved to the back of the grid so a clip shows overtakes.
static func _back_of_grid_config(car: StringName, track: StringName, race_seed: int) -> RaceConfig:
	var config: RaceConfig = RaceLauncher.build_solo_config(car, track, race_seed)
	var local: RaceConfig.Participant = config.local_participant()
	config.participants.erase(local)
	config.participants.append(local)
	return config


static func _note(log: Array[String], tick: int, relevant: bool, label: String) -> void:
	if relevant:
		log.append("%d %s" % [tick, label])
