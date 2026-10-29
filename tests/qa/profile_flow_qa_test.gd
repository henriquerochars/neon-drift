extends GdUnitTestSuite
## Scene-level garage acceptance; all persistence is redirected to disposable test files.

const SETTINGS_SCRIPT: GDScript = preload("res://src/core/game_settings.gd")
const APP: PackedScene = preload("res://src/ui/app/app.tscn")
const PROFILE: String = "user://test-qa-profile.json"
const SETTINGS: String = "user://test-qa-settings.cfg"
const FUNDS: int = 100000
const FIELDS: Dictionary = {
	&"engine": "top_speed",
	&"turbo": "acceleration",
	&"tires": "handling",
	&"nitro_tank": "nitro_duration",
	&"thrusters": "jump_velocity",
	&"armour": "max_integrity"
}

var _app: App


func before_test() -> void:
	UiPaths.profile_path = PROFILE
	UiPaths.settings_path = SETTINGS
	PlayerProfile.reset()
	PlayerProfile.money = FUNDS
	_app = auto_free(APP.instantiate()) as App
	add_child(_app)


func after_test() -> void:
	_app.router.go(ScreenRouter.SCREEN_MENU)
	AudioDirector.stop_all()
	PlayerProfile.reset()
	UiPaths.reset()
	for path: String in [PROFILE, SETTINGS]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_all_tiers_paint_repair_and_profile_round_trip() -> void:
	var garage: GarageScreen = _app.router.go(ScreenRouter.SCREEN_GARAGE) as GarageScreen
	var car: StringName = garage.current_car().id
	for slot: StringName in Constants.SLOTS:
		for part: PartDef in Catalog.parts_for_slot(slot):
			var before: CarStats = Catalog.stats_for(car, PlayerProfile.parts.get(car, {}))
			var money: int = PlayerProfile.money
			assert_bool(garage.buy(slot)).is_true()
			assert_int(PlayerProfile.money).is_equal(money - part.price)
			assert_int(PlayerProfile.tier_of(car, slot)).is_equal(part.tier)
			var after: CarStats = Catalog.stats_for(car, PlayerProfile.parts[car])
			assert_float(float(after.get(FIELDS[slot]))).is_greater(float(before.get(FIELDS[slot])))
	for paint: int in range(Constants.PAINT_COUNT):
		garage.cycle_paint()
		assert_int(PlayerProfile.paint_of(car)).is_equal((paint + 1) % Constants.PAINT_COUNT)
	PlayerProfile.set_integrity(car, 25.0)
	var repair_cost: int = garage.repair_price()
	var money: int = PlayerProfile.money
	assert_bool(garage.repair()).is_true()
	assert_int(PlayerProfile.money).is_equal(money - repair_cost)
	assert_float(PlayerProfile.integrity_of(car)).is_equal(100.0)
	var expected: Dictionary = PlayerProfile.to_dictionary()
	garage.leave()
	PlayerProfile.reset()
	assert_bool(PlayerProfile.load_profile(PROFILE)).is_true()
	assert_dict(PlayerProfile.to_dictionary()).is_equal(expected)


func test_settings_round_trip() -> void:
	var settings: Node = auto_free(SETTINGS_SCRIPT.new()) as Node
	settings.set("apply_to_window", false)
	var values: Dictionary = {
		"master_volume": 0.25,
		"music_volume": 0.5,
		"sfx_volume": 0.75,
		"fullscreen": true,
		"vsync": false,
		"show_fps": true,
		"window_scale": 2,
		"player_name": "QA TEST"
	}
	for key: String in values:
		settings.set(key, values[key])
	assert_int(int(settings.call("save_settings", SETTINGS))).is_equal(OK)
	var restored: Node = auto_free(SETTINGS_SCRIPT.new()) as Node
	restored.call("load_settings", SETTINGS)
	for key: String in values:
		assert_that(restored.get(key)).is_equal(values[key])


func test_solo_reaches_results_and_persists_earnings() -> void:
	var select: SelectScreen = _app.router.go(ScreenRouter.SCREEN_SELECT) as SelectScreen
	select.confirm()
	select.launch_race(7)
	var host: RaceHost = _app.router.current as RaceHost
	var race: RaceScene = host.race as RaceScene
	race.set_physics_process(false)
	var driver: AiDriver = AiDriver.new()
	driver.setup(race.track_model, 0.8, 106, race.local_id())
	race.set_local_input_source(driver)
	var money: int = PlayerProfile.money
	for _tick: int in range(18000):
		if _app.router.current_name == ScreenRouter.SCREEN_RESULTS:
			break
		race.step_tick(1.0 / Balance.value(&"fps_reference"))
	assert_str(String(_app.router.current_name)).is_equal(String(ScreenRouter.SCREEN_RESULTS))
	var results: ResultsScreen = _app.router.current as ResultsScreen
	assert_int(PlayerProfile.money).is_equal(money + results.earnings)
	var expected: Dictionary = PlayerProfile.to_dictionary()
	PlayerProfile.reset()
	assert_bool(PlayerProfile.load_profile(PROFILE)).is_true()
	assert_dict(PlayerProfile.to_dictionary()).is_equal(expected)
