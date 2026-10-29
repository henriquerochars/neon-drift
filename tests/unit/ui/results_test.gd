extends GdUnitTestSuite
## The results screen records place, earnings and final integrity into PlayerProfile.

const RESULTS_SCENE: String = "res://src/ui/results/results_screen.tscn"
const PROFILE_PATH: String = "user://test-ui-results-profile.json"
const SEED: int = 42
const LOCAL_ID: int = 0
const FINAL_INTEGRITY: float = 55.0
const CAR_ID: StringName = &"vortex"
const TRACK_ID: StringName = &"coast"

var _screen: ResultsScreen


func before_test() -> void:
	PlayerProfile.reset()
	UiPaths.profile_path = PROFILE_PATH
	var scene: PackedScene = load(RESULTS_SCENE) as PackedScene
	_screen = auto_free(scene.instantiate()) as ResultsScreen
	add_child(_screen)
	await await_idle_frame()


func after_test() -> void:
	AudioDirector.stop_all()
	PlayerProfile.reset()
	UiPaths.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))


func test_present_records_earnings_and_integrity() -> void:
	var config: RaceConfig = RaceLauncher.build_solo_config(CAR_ID, TRACK_ID, SEED)
	var results: Array[Dictionary] = _results_for(config, 3)
	var money_before: int = PlayerProfile.money
	_screen.present(results, LOCAL_ID, FINAL_INTEGRITY, config)
	var expected: int = Catalog.track(TRACK_ID).prizes[2]
	assert_int(_screen.earnings).is_equal(expected)
	assert_int(PlayerProfile.money).is_equal(money_before + expected)
	assert_int(PlayerProfile.races).is_equal(1)
	assert_int(PlayerProfile.wins).is_equal(0)
	assert_float(PlayerProfile.integrity_of(CAR_ID)).is_equal(FINAL_INTEGRITY)
	assert_int(_screen.rows_box.get_child_count()).is_equal(Constants.MAX_PLAYERS)
	assert_str(_screen.place_label.text).is_equal("3RD")
	assert_str(_screen.seed_label.text).is_equal("SEED %d" % SEED)
	assert_bool(FileAccess.file_exists(PROFILE_PATH)).is_true()
	assert_bool(FileAccess.file_exists(PlayerProfile.PATH)).is_false()
	assert_bool(_screen.again_button.visible).is_true()
	assert_bool(_screen.room_button.visible).is_false()


func test_enter_with_args_counts_a_win_and_online_shows_the_room_button() -> void:
	var config: RaceConfig = RaceLauncher.build_solo_config(CAR_ID, TRACK_ID, SEED)
	config.online = true
	var results: Array[Dictionary] = _results_for(config, 1)
	var args: Dictionary = {
		"results": results,
		"local_id": LOCAL_ID,
		"integrity": PlayerProfile.FULL_INTEGRITY,
		"config": config,
		"online": true,
	}
	_screen.enter(args)
	assert_int(PlayerProfile.wins).is_equal(1)
	assert_int(PlayerProfile.money).is_equal(
		PlayerProfile.STARTING_MONEY + Catalog.track(TRACK_ID).prizes[0]
	)
	assert_bool(_screen.room_button.visible).is_true()
	assert_bool(_screen.again_button.visible).is_false()


## Results array in the RaceBus.race_finished shape; the local car takes `local_place`.
func _results_for(config: RaceConfig, local_place: int) -> Array[Dictionary]:
	var prizes: Array[int] = Catalog.track(TRACK_ID).prizes
	var results: Array[Dictionary] = []
	var next_place: int = 1
	for participant: RaceConfig.Participant in config.participants:
		var place: int = local_place
		if participant.kind != RaceConfig.KIND_LOCAL:
			if next_place == local_place:
				next_place += 1
			place = next_place
			next_place += 1
		var entry: Dictionary = {
			"id": participant.id,
			"name": participant.display_name,
			"car_id": participant.car_id,
			"place": place,
			"time": 60.0 + place,
			"earnings": prizes[place - 1],
			"finished": true,
		}
		results.append(entry)
	return results


func after() -> void:
	AudioDirector.stop_all()


func test_profile_and_retry_use_current_upgrades_paint_and_damage() -> void:
	var old: RaceConfig = RaceLauncher.build_solo_config(CAR_ID, TRACK_ID, SEED)
	PlayerProfile.parts[CAR_ID] = {&"engine": 2}
	PlayerProfile.set_paint(CAR_ID, 3)
	PlayerProfile.set_integrity(CAR_ID, FINAL_INTEGRITY)
	var profile: Resource = LobbyAdapter.make_profile("Driver", CAR_ID, 3)
	assert_dict(profile.get("tiers")).is_equal({&"engine": 2})
	assert_float(profile.get("integrity")).is_equal(FINAL_INTEGRITY)
	var router: ScreenRouter = auto_free(ScreenRouter.new())
	var launcher: RaceLauncher = auto_free(RaceLauncher.new())
	router.launcher = launcher
	_screen.router = router
	_screen.config = old
	_screen.race_again()
	var next: RaceConfig = launcher.last_config
	assert_bool(next == old).is_false()
	assert_int(old.seed).is_equal(SEED)
	assert_int(next.seed).is_not_equal(SEED)
	assert_dict(next.local_participant().tiers).is_equal({&"engine": 2})
	assert_int(next.local_participant().paint).is_equal(3)
	assert_float(next.local_participant().integrity).is_equal(FINAL_INTEGRITY)


func test_online_results_refresh_room_integrity() -> void:
	assert_int(NetSession.host(0, LobbyProfile.new())).is_equal(OK)
	var config: RaceConfig = RaceLauncher.build_solo_config(CAR_ID, TRACK_ID, SEED)
	_screen.present(_results_for(config, 1), LOCAL_ID, FINAL_INTEGRITY, config, true)
	assert_float(NetSession.local_seat().integrity).is_equal(FINAL_INTEGRITY)
	NetSession.leave()
