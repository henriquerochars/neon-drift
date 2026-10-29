extends Node
## Screenshot every UI screen at 320x180. Needs a display (xvfb-run on CI machines):
##   xvfb-run -a tools/godot.sh res://tools/playtest/capture_screens.tscn -- --output=/tmp/screens
## Writes <output>/<screen>.png and manifest.json (commit, screens). The profile and the
## settings are redirected to user://capture-*.json so the player's files are never touched.

const APP_SCENE: PackedScene = preload("res://src/ui/app/app.tscn")
const PROFILE_PATH: String = "user://capture-profile.json"
const SETTINGS_PATH: String = "user://capture-settings.cfg"
const SETTLE_FRAMES: int = 6
const RESULTS_SEED: int = 271029
const LOCAL_ID: int = 0
const LOCAL_PLACE: int = 2
const LOCAL_INTEGRITY: float = 64.0
const HUD_SPEED: float = 8800.0
const HUD_TIME: float = 47.3
const HUD_PLACE: int = 3
const HUD_LAP: int = 1
const RIVAL_PAINT_SEED: int = 7

var _output: String = "/tmp/neon-drift-screens"
var _app: App
var _manifest: Array[String] = []
var _failed: bool = false


class HudFixture:
	extends Node
	## Minimal race double so the HUD can be rendered without the race lane.

	var config: RaceConfig = RaceConfig.new()
	var track_model: TrackModel
	var race_time: float = HUD_TIME
	var states: Dictionary = {}
	var order: Array[int] = []

	func _init() -> void:
		config = RaceLauncher.build_solo_config(&"vortex", &"coast", RESULTS_SEED)
		track_model = TrackModel.new(Catalog.track(&"coast"))
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = RIVAL_PAINT_SEED
		for participant: RaceConfig.Participant in config.participants:
			var state: CarState = CarState.new()
			state.speed = (
				HUD_SPEED if participant.id == LOCAL_ID else rng.randf_range(0.0, HUD_SPEED)
			)
			state.nitro = 0.7 if participant.id == LOCAL_ID else rng.randf()
			state.thrusters = 1.0
			state.integrity = LOCAL_INTEGRITY if participant.id == LOCAL_ID else 100.0
			state.lap = HUD_LAP
			state.progress = track_model.length * (HUD_LAP + rng.randf())
			states[participant.id] = state
			order.append(participant.id)
		order.sort_custom(
			func(a: int, b: int) -> bool:
				return (states[a] as CarState).progress > (states[b] as CarState).progress
		)

	func state_of(id: int) -> CarState:
		return states.get(id)

	func stats_of(id: int) -> CarStats:
		var participant: RaceConfig.Participant = config.participants[id]
		return Catalog.stats_for(participant.car_id, participant.tiers)

	func place_of(id: int) -> int:
		return order.find(id) + 1

	func lap_of(_id: int) -> int:
		return HUD_LAP

	func local_id() -> int:
		return LOCAL_ID

	func standings() -> Array[int]:
		return order


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			_output = argument.trim_prefix("--output=")
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_output)
	PlayerProfile.reset()
	GameSettings.apply_to_window = false
	UiPaths.profile_path = PROFILE_PATH
	UiPaths.settings_path = SETTINGS_PATH
	_app = APP_SCENE.instantiate() as App
	add_child(_app)
	await _settle()
	var router: ScreenRouter = _app.router
	await _shoot("title")
	router.go(ScreenRouter.SCREEN_MENU)
	await _shoot("menu")
	var garage: GarageScreen = router.go(ScreenRouter.SCREEN_GARAGE) as GarageScreen
	garage.buy(&"engine")
	garage.buy(&"tires")
	PlayerProfile.set_integrity(garage.current_car().id, LOCAL_INTEGRITY)
	garage.refresh()
	await _shoot("garage")
	var options: OptionsScreen = router.go(ScreenRouter.SCREEN_OPTIONS) as OptionsScreen
	await _shoot("options")
	options.show_controls()
	await _shoot("options_controls")
	var select: SelectScreen = router.go(ScreenRouter.SCREEN_SELECT) as SelectScreen
	await _shoot("select_car")
	select.show_tracks()
	await _shoot("select_track")
	var lobby: LobbyScreen = router.go(ScreenRouter.SCREEN_LOBBY) as LobbyScreen
	await _shoot("lobby_connect")
	lobby.host()
	lobby.toggle_ready()
	await _shoot("lobby_host")
	await _capture_hud(router)
	await _capture_results(router)
	_write_manifest()
	get_tree().quit(1 if _failed else 0)


func _capture_hud(router: ScreenRouter) -> void:
	var host: RaceHost = router.go(ScreenRouter.SCREEN_RACE) as RaceHost
	var fixture: HudFixture = HudFixture.new()
	host.add_child(fixture)
	host.race = fixture
	host.placeholder.visible = false
	host.hud.bind(fixture)
	host.hud.flash("LAP 2")
	await _shoot("hud")
	host.set_paused(true)
	await _shoot("pause")
	host.hud.unbind()


func _capture_results(router: ScreenRouter) -> void:
	var config: RaceConfig = RaceLauncher.build_solo_config(
		PlayerProfile.selected_car, &"sunset_city", RESULTS_SEED
	)
	var prizes: Array[int] = Catalog.track(&"sunset_city").prizes
	var results: Array[Dictionary] = []
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = RESULTS_SEED
	var next_place: int = 1
	for participant: RaceConfig.Participant in config.participants:
		var place: int = LOCAL_PLACE
		if participant.kind != RaceConfig.KIND_LOCAL:
			if next_place == LOCAL_PLACE:
				next_place += 1
			place = next_place
			next_place += 1
		var entry: Dictionary = {
			"id": participant.id,
			"name": participant.display_name,
			"car_id": participant.car_id,
			"place": place,
			"time": 95.0 + place * 1.7,
			"earnings": prizes[place - 1],
			"finished": place < Constants.MAX_PLAYERS,
		}
		results.append(entry)
	var args: Dictionary = {
		"results": results,
		"local_id": LOCAL_ID,
		"integrity": LOCAL_INTEGRITY,
		"config": config,
		"online": false,
	}
	router.go(ScreenRouter.SCREEN_RESULTS, args)
	await _shoot("results")


func _settle() -> void:
	for _frame: int in range(SETTLE_FRAMES):
		await get_tree().process_frame


func _shoot(name: String) -> void:
	await _settle()
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _output.path_join("%s.png" % name)
	if image.save_png(path) != OK:
		push_error("capture_screens: cannot write %s" % path)
		_failed = true
		return
	_manifest.append(name)
	print("captured %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _write_manifest() -> void:
	var file: FileAccess = FileAccess.open(_output.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		_failed = true
		return
	var manifest: Dictionary = {
		"screens": _manifest,
		"viewport": [Constants.VIEWPORT_WIDTH, Constants.VIEWPORT_HEIGHT],
		"seed": RESULTS_SEED,
	}
	file.store_string(JSON.stringify(manifest, "\t"))
