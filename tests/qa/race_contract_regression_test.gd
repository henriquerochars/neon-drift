extends GdUnitTestSuite
## Known contract failures at 4d6aadc. Deliberately failing regression tests.

const SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const SEED: int = 7
const FINISH_TIME: float = 70.0


func _race() -> RaceScene:
	var race: RaceScene = auto_free(SCENE.instantiate()) as RaceScene
	add_child(race)
	race.set_physics_process(false)
	var config: RaceConfig = RaceLauncher.build_solo_config(&"vortex", &"coast", SEED)
	race.start(config)
	return race


func test_countdown_place_is_one_based() -> void:
	var race: RaceScene = _race()
	assert_int(race.place_of(race.local_id())).is_greater(0)


func test_authoritative_finish_replaces_predicted_client_finish() -> void:
	var race: RaceScene = _race()
	race.set_authority(false)
	race.force_phase(Constants.PHASE_RACING, FINISH_TIME)
	var state: CarState = race.state_of(race.local_id())
	state.lap = race.config.laps
	race.step_tick(1.0 / Balance.value(&"fps_reference"))
	assert_bool(state.finished).is_true()
	race.force_finish(race.local_id(), 2, FINISH_TIME)
	assert_int(race.place_of(race.local_id())).is_equal(2)
	assert_float(state.finish_time).is_equal(FINISH_TIME)
