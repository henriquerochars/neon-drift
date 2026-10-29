extends GdUnitTestSuite
## CarSim acceptance: acceleration to top speed, nitro burst, jump arc, lap wrap, crush rules.

const DT: float = 1.0 / 60.0


func _track() -> TrackModel:
	return TrackModel.new(Catalog.track(&"coast"))


## A long straight so an unsteered car never leaves the road.
func _straight() -> TrackModel:
	var track: TrackDef = TrackDef.new()
	var piece: TrackSegment = TrackSegment.new()
	piece.enter = 0
	piece.hold = 2000
	piece.leave = 0
	track.pieces = [piece]
	return TrackModel.new(track)


func _stats(car_id: StringName = &"vortex") -> CarStats:
	return Catalog.stats_for(car_id, {})


func _run(
	state: CarState,
	source: ScriptedDriverInputSource,
	stats: CarStats,
	track: TrackModel,
	ticks: int
) -> int:
	var events: int = 0
	for _i: int in range(ticks):
		events |= CarSim.step(state, source.sample(DT), stats, track, DT)
	return events


func test_full_throttle_reaches_top_speed_and_stays_there() -> void:
	var state: CarState = CarState.new()
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.hold(0.0, 1.0)
	var stats: CarStats = _stats()
	_run(state, source, stats, _straight(), 60 * 10)
	assert_float(state.speed).is_equal_approx(stats.top_speed, 0.01)
	assert_float(state.z).is_greater(0.0)


func test_nitro_raises_top_speed_then_runs_out() -> void:
	var state: CarState = CarState.new()
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.hold(0.0, 1.0)
	var stats: CarStats = _stats(&"phantom")
	var track: TrackModel = _straight()
	_run(state, source, stats, track, 60 * 6)
	source.press_nitro()
	var events: int = _run(state, source, stats, track, 30)
	assert_int(events & CarSim.EVENT_NITRO).is_not_equal(0)
	assert_bool(state.is_nitro_active()).is_true()
	assert_float(state.speed).is_greater(stats.top_speed)
	_run(state, source, stats, track, 60 * 8)
	assert_bool(state.is_nitro_active()).is_false()
	assert_float(state.speed).is_equal_approx(stats.top_speed, 0.01)


func test_jump_rises_and_lands_recharging_thrusters() -> void:
	var state: CarState = CarState.new()
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.hold(0.0, 1.0)
	var stats: CarStats = _stats(&"mirage")
	source.press_jump()
	var events: int = _run(state, source, stats, _track(), 5)
	assert_int(events & CarSim.EVENT_JUMP).is_not_equal(0)
	assert_bool(state.airborne).is_true()
	assert_float(state.altitude).is_greater(0.0)
	assert_float(state.thrusters).is_equal(0.0)
	events = _run(state, source, stats, _track(), 60 * 3)
	assert_int(events & CarSim.EVENT_LANDED).is_not_equal(0)
	assert_bool(state.airborne).is_false()
	assert_float(state.altitude).is_equal(0.0)
	assert_float(state.thrusters).is_greater(0.0)


func test_cannot_jump_without_full_thrusters() -> void:
	var state: CarState = CarState.new()
	state.thrusters = 0.5
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.press_jump()
	var events: int = _run(state, source, _stats(), _track(), 1)
	assert_int(events & CarSim.EVENT_JUMP).is_equal(0)
	assert_bool(state.airborne).is_false()


func test_crossing_the_finish_line_counts_a_lap() -> void:
	var track: TrackModel = _track()
	var state: CarState = CarState.new()
	state.z = track.length - 10.0
	state.speed = 5000.0
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.hold(0.0, 1.0)
	var events: int = _run(state, source, _stats(), track, 2)
	assert_int(events & CarSim.EVENT_LAP).is_not_equal(0)
	assert_int(state.lap).is_equal(1)
	assert_float(state.z).is_less(track.length)
	assert_float(state.progress).is_greater(track.length)


func test_offroad_slows_the_car_and_reports_it() -> void:
	var state: CarState = CarState.new()
	state.x = 1.5
	state.speed = 12000.0
	var source: ScriptedDriverInputSource = ScriptedDriverInputSource.new()
	source.hold(0.0, 1.0)
	var stats: CarStats = _stats()
	var events: int = _run(state, source, stats, _track(), 60)
	assert_int(events & CarSim.EVENT_OFFROAD_ENTER).is_not_equal(0)
	assert_float(state.speed).is_less(stats.top_speed * 0.5)


func test_crush_hurts_victim_more_than_jumper() -> void:
	var jumper: CarState = CarState.new()
	var victim: CarState = CarState.new()
	jumper.speed = 10000.0
	victim.speed = 10000.0
	CarSim.resolve_crush(jumper, victim)
	assert_float(victim.speed).is_less(jumper.speed)
	assert_float(victim.integrity).is_less(jumper.integrity)
	assert_float(jumper.integrity).is_less(100.0)
	assert_float(victim.stun_time).is_greater(0.0)


func test_overlap_wraps_around_the_track() -> void:
	var a: CarState = CarState.new()
	var b: CarState = CarState.new()
	a.z = 10.0
	b.z = 9990.0
	assert_bool(CarSim.overlaps(a, b, 10000.0)).is_true()
	b.x = 1.0
	assert_bool(CarSim.overlaps(a, b, 10000.0)).is_false()


func test_bump_pushes_cars_apart() -> void:
	var a: CarState = CarState.new()
	var b: CarState = CarState.new()
	a.x = 0.1
	b.x = 0.0
	a.speed = 8000.0
	b.speed = 8000.0
	assert_bool(CarSim.resolve_bump(a, b)).is_true()
	assert_float(a.x).is_greater(b.x + 0.2)
	assert_float(a.speed).is_less(8000.0)
