extends GdUnitTestSuite
## Contact rules in the race scene: a jumper landing on a car crushes it, two grounded cars
## side by side bump, and the authority flag gates both.

const SCENE: PackedScene = preload("res://src/gameplay/race/race_scene.tscn")
const DT: float = 1.0 / 60.0
const START_Z: float = 5000.0

var _crushes: Array = []
var _bumps: Array = []


func before_test() -> void:
	_crushes = []
	_bumps = []
	RaceBus.car_crushed.connect(_on_crushed)
	RaceBus.car_bumped.connect(_on_bumped)


func after_test() -> void:
	RaceBus.car_crushed.disconnect(_on_crushed)
	RaceBus.car_bumped.disconnect(_on_bumped)


func _on_crushed(attacker: int, victim: int) -> void:
	_crushes.append([attacker, victim])


func _on_bumped(participant_id: int) -> void:
	_bumps.append(participant_id)


func _scene() -> RaceScene:
	var config: RaceConfig = RaceConfig.new()
	config.track_id = &"coast"
	config.seed = 1
	config.add_participant(0, "A", &"vortex", RaceConfig.KIND_AI)
	config.add_participant(1, "B", &"vortex", RaceConfig.KIND_AI)
	var scene: RaceScene = auto_free(SCENE.instantiate())
	scene.set_physics_process(false)
	add_child(scene)
	scene.start(config)
	scene.force_phase(Constants.PHASE_RACING, 0.0)
	for participant: RaceParticipant in scene.participants:
		participant.source = ScriptedDriverInputSource.new()
		participant.state.z = START_Z
		participant.state.x = 0.0
		participant.state.speed = 6000.0
	return scene


func test_landing_on_a_car_crushes_it() -> void:
	var scene: RaceScene = _scene()
	var jumper: ScriptedDriverInputSource = scene.participants[0].source
	var victim: ScriptedDriverInputSource = scene.participants[1].source
	jumper.hold(0.0, 1.0)
	victim.hold(0.0, 1.0)
	jumper.press_jump()
	scene.step_tick(DT)
	assert_bool(scene.state_of(0).airborne).is_true()
	assert_int(_bumps.size()).is_equal(0)
	var speed_before: float = scene.state_of(1).speed
	for _tick: int in range(180):
		scene.step_tick(DT)
		if not _crushes.is_empty():
			break
	assert_array(_crushes).contains([[0, 1]])
	assert_float(scene.state_of(1).speed).is_less(speed_before)
	assert_float(scene.state_of(1).speed).is_less(scene.state_of(0).speed)
	assert_float(scene.state_of(1).integrity).is_less(100.0)
	assert_float(scene.state_of(1).stun_time).is_greater(0.0)
	remove_child(scene)


func test_side_by_side_cars_bump_once() -> void:
	var scene: RaceScene = _scene()
	scene.participants[0].state.x = 0.1
	scene.step_tick(DT)
	assert_array(_bumps).contains_exactly_in_any_order([0, 1])
	assert_float(scene.state_of(0).x).is_greater(scene.state_of(1).x + 0.2)
	assert_float(scene.state_of(0).speed).is_less(6000.0)
	scene.step_tick(DT)
	assert_int(_bumps.size()).is_equal(2)
	remove_child(scene)


func test_client_does_not_resolve_contacts_but_applies_penalties() -> void:
	var scene: RaceScene = _scene()
	scene.set_authority(false)
	scene.participants[0].state.x = 0.1
	scene.step_tick(DT)
	assert_int(_bumps.size()).is_equal(0)
	var speed_before: float = scene.state_of(0).speed
	scene.apply_penalty(0, RacePenalties.KIND_BUMP)
	assert_array(_bumps).contains_exactly([0])
	assert_float(scene.state_of(0).speed).is_less(speed_before)
	remove_child(scene)
