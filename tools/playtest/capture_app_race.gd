extends Node
## Capture the real solo UI with AI input. Same track/seed/output arguments as capture_race.

const APP: PackedScene = preload("res://src/ui/app/app.tscn")
const TICKS: int = 480
const EVERY: int = 4
const SKILL: float = 0.8


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args: Dictionary = PlaytestArgs.parse(OS.get_cmdline_user_args())
	var output: String = str(args.get("output", "/tmp/app-race"))
	var track: StringName = StringName(str(args.get("track", "coast")))
	var race_seed: int = int(args.get("seed", 7))
	DirAccess.make_dir_recursive_absolute(output)
	UiPaths.profile_path = "user://test-qa-capture-profile.json"
	UiPaths.settings_path = "user://test-qa-capture-settings.cfg"
	PlayerProfile.reset()
	var app: App = APP.instantiate() as App
	add_child(app)
	var select: SelectScreen = app.router.go(ScreenRouter.SCREEN_SELECT) as SelectScreen
	select.confirm_button.pressed.emit()
	for index: int in range(Catalog.tracks().size()):
		if Catalog.tracks()[index].id == track:
			select.track_index = index
	select.launch_race(race_seed)
	var host: RaceHost = app.router.current as RaceHost
	var race: RaceScene = host.race as RaceScene
	race.set_physics_process(false)
	var driver: AiDriver = AiDriver.new()
	driver.setup(race.track_model, SKILL, race_seed + 99, race.local_id())
	race.set_local_input_source(driver)
	var delta: float = 1.0 / Balance.value(&"fps_reference")
	var samples: Array[Dictionary] = []
	for tick: int in range(TICKS):
		race.step_tick(delta)
		race.refresh_view()
		if tick % EVERY != 0:
			continue
		await RenderingServer.frame_post_draw
		var image: Image = get_viewport().get_texture().get_image()
		image.save_png("%s/frame_%04d.png" % [output, tick])
		var state: CarState = race.state_of(race.local_id())
		samples.append(
			{
				"tick": tick,
				"speed": state.speed,
				"nitro": state.nitro,
				"altitude": state.altitude,
				"integrity": state.integrity
			}
		)
	var file: FileAccess = FileAccess.open(output.path_join("samples.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(samples, "\t"))
	print("QA_APP_CAPTURE_DONE frames=120")
	get_tree().quit()
