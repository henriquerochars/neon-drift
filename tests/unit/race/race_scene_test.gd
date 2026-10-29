extends GdUnitTestSuite
## RaceScene acceptance: a seeded 8-car AI race on coast finishes with a deterministic,
## duplicate-free result table whose earnings follow the track prizes.

const SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const DT: float = 1.0 / 60.0
const MAX_TICKS: int = 18000
const CARS: int = 8
const SEED: int = 3


func _config(race_seed: int) -> RaceConfig:
	var config: RaceConfig = RaceConfig.new()
	config.track_id = &"coast"
	config.laps = 3
	config.seed = race_seed
	var cars: Array[CarDef] = Catalog.cars()
	for index: int in range(CARS):
		var car: CarDef = cars[index % cars.size()]
		var participant: RaceConfig.Participant = config.add_participant(
			index, "AI %d" % index, car.id, RaceConfig.KIND_AI, index
		)
		participant.skill = 0.3 + 0.7 * float(index) / float(CARS - 1)
	return config


func _run(race_seed: int) -> RaceScene:
	var scene: RaceScene = auto_free(SCENE.instantiate())
	scene.set_physics_process(false)
	add_child(scene)
	scene.start(_config(race_seed))
	for _tick: int in range(MAX_TICKS):
		scene.step_tick(DT)
		if scene.phase == Constants.PHASE_FINISHED:
			break
	remove_child(scene)
	return scene


func test_countdown_then_racing() -> void:
	var scene: RaceScene = auto_free(SCENE.instantiate())
	scene.set_physics_process(false)
	add_child(scene)
	scene.start(_config(SEED))
	assert_str(scene.phase).is_equal(Constants.PHASE_COUNTDOWN)
	assert_int(scene.lap_of(0)).is_equal(1)
	for _tick: int in range(int(RaceScene.COUNTDOWN_SECONDS * 60.0) + 2):
		scene.step_tick(DT)
	assert_str(scene.phase).is_equal(Constants.PHASE_RACING)
	assert_int(scene.standings().size()).is_equal(CARS)
	remove_child(scene)


func test_seeded_ai_race_finishes_with_unique_places() -> void:
	var scene: RaceScene = _run(SEED)
	assert_str(scene.phase).is_equal(Constants.PHASE_FINISHED)
	var results: Array[Dictionary] = scene.results()
	assert_int(results.size()).is_equal(CARS)
	var places: Array[int] = []
	for index: int in range(CARS):
		var place: int = scene.place_of(index)
		assert_int(place).is_between(1, CARS)
		assert_bool(places.has(place)).is_false()
		places.append(place)
		assert_bool(scene.state_of(index).finished).is_true()
		assert_int(scene.lap_of(index)).is_equal(3)
	var first: Dictionary = results[0]
	var last: Dictionary = results[CARS - 1]
	assert_int(int(first["place"])).is_equal(1)
	assert_int(int(last["place"])).is_equal(CARS)
	assert_int(int(first["earnings"])).is_greater(int(last["earnings"]))
	assert_float(float(first["time"])).is_less_equal(float(last["time"]))
	assert_bool(bool(first["finished"])).is_true()


func test_same_seed_gives_the_same_places() -> void:
	var a: RaceScene = _run(SEED)
	var b: RaceScene = _run(SEED)
	for index: int in range(CARS):
		assert_int(a.place_of(index)).is_equal(b.place_of(index))
		assert_float(a.state_of(index).finish_time).is_equal(b.state_of(index).finish_time)
	assert_array(a.standings()).is_equal(b.standings())
