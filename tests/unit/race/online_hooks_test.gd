extends GdUnitTestSuite

const SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const DT: float = 0.1

var _race: RaceScene


func before_test() -> void:
	_race = auto_free(SCENE.instantiate())
	add_child(_race)
	_race.set_physics_process(false)
	var config: RaceConfig = RaceConfig.new()
	config.track_id = &"coast"
	for id: int in range(Constants.MAX_PLAYERS):
		config.add_participant(
			id, str(id), &"vortex", RaceConfig.KIND_LOCAL if id == 0 else RaceConfig.KIND_REMOTE
		)
	_race.start(config)
	_race.set_authority(false)


func after_test() -> void:
	AudioDirector.stop_all()


func test_predicted_finish_is_confirmed_once_and_results_are_authoritative() -> void:
	var finishes: Array[int] = []
	var tables: Array = []
	var on_finish: Callable = func(id: int, _place: int, _time: float) -> void: finishes.append(id)
	var on_results: Callable = func(entries: Array[Dictionary]) -> void: tables.append(entries)
	RaceBus.car_finished.connect(on_finish)
	RaceBus.race_finished.connect(on_results)
	_race.force_phase(Constants.PHASE_RACING, 10.0)
	_race.state_of(0).finished = true
	_race.participants[0].place = 1
	_race.force_finish(0, 3, 9.5)
	_race.force_finish(0, 3, 9.5)
	assert_int(_race.place_of(0)).is_equal(3)
	assert_float(_race.state_of(0).finish_time).is_equal(9.5)
	assert_array(finishes).contains_exactly([0])
	_race.step_tick(RaceScene.RACE_END_GRACE + 1.0)
	assert_str(_race.phase).is_equal(Constants.PHASE_RACING)
	var entries: Array[Dictionary] = []
	for id: int in range(Constants.MAX_PLAYERS):
		entries.append({"id": id, "place": id + 1})
	_race.force_results(entries)
	_race.force_results(entries)
	assert_int(_race.results().size()).is_equal(Constants.MAX_PLAYERS)
	assert_int(tables.size()).is_equal(1)
	assert_str(_race.phase).is_equal(Constants.PHASE_FINISHED)
	RaceBus.car_finished.disconnect(on_finish)
	RaceBus.race_finished.disconnect(on_results)


func test_phase_resync_does_not_restart_or_repeat_go() -> void:
	var starts: Array[int] = []
	var callback: Callable = func() -> void: starts.append(1)
	RaceBus.race_started.connect(callback)
	_race.force_phase(Constants.PHASE_COUNTDOWN, 2.0)
	_race.step_tick(0.25)
	_race.force_phase(Constants.PHASE_COUNTDOWN, 1.0)
	assert_float(_race.get("_countdown_left")).is_equal(1.0)
	_race.force_phase(Constants.PHASE_RACING, 0.0)
	_race.step_tick(DT)
	_race.force_phase(Constants.PHASE_RACING, 0.0)
	assert_float(_race.race_time).is_equal(DT)
	assert_array(starts).contains_exactly([1])
	RaceBus.race_started.disconnect(callback)


func test_simultaneous_crossings_use_time_then_id() -> void:
	_race.set_authority(true)
	_race.force_phase(Constants.PHASE_RACING, 10.0)
	for participant: RaceParticipant in _race.participants:
		participant.source = null
		participant.state.lap = _race.config.laps
		participant.state.speed = 1000.0
		participant.state.z = 20.0
		participant.state.progress = _race.track_model.length * _race.config.laps + 20.0
	_race.state_of(1).progress += 50.0
	_race.step_tick(DT)
	assert_int(_race.place_of(1)).is_equal(1)
	assert_int(_race.place_of(0)).is_equal(2)
	assert_int(_race.place_of(2)).is_equal(3)
	assert_float(_race.state_of(1).finish_time).is_less(_race.state_of(0).finish_time)


func test_finished_car_is_excluded_and_coast_wraps() -> void:
	var contacts: RaceContacts = RaceContacts.new()
	contacts.setup(_race.track_model)
	var a: RaceParticipant = _race.participants[0]
	var b: RaceParticipant = _race.participants[1]
	a.state.z = 100.0
	b.state.z = 100.0
	a.state.x = 0.0
	b.state.x = 0.0
	a.state.finished = true
	var pair: Array[RaceParticipant] = [a, b]
	assert_array(contacts.detect(pair, DT)).is_empty()
	pair.reverse()
	assert_array(contacts.detect(pair, DT)).is_empty()
	a.state.z = _race.track_model.length - 1.0
	a.state.speed = 1000.0
	CarSim.step(a.state, DriverInput.new(), a.stats, _race.track_model, DT)
	assert_float(a.state.z).is_between(0.0, _race.track_model.length)


func test_bump_uses_host_push_even_on_same_side_of_road() -> void:
	var state: CarState = _race.state_of(0)
	state.x = 0.5
	state.speed = 1000.0
	_race.apply_penalty(0, &"bump", {"push": -0.15, "speed_ratio": 0.8})
	assert_float(state.x).is_equal_approx(0.35, 0.0001)
	assert_float(state.speed).is_equal(800.0)
