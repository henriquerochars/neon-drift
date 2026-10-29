extends GdUnitTestSuite
## AiDriver acceptance: alone on each track it completes a lap within 9000 ticks while
## staying on the road at least 95% of the time, deterministically for a seed.

const DT: float = 1.0 / 60.0
const MAX_TICKS: int = 9000
const OFFROAD_LIMIT: float = 0.05


func _drive(track_id: StringName, rng_seed: int) -> Dictionary:
	var model: TrackModel = TrackModel.new(Catalog.track(track_id))
	var state: CarState = CarState.new()
	var stats: CarStats = Catalog.stats_for(&"vortex", {})
	var driver: AiDriver = AiDriver.new()
	driver.setup(model, 0.5, rng_seed, 0)
	driver.bind(state, stats)
	var offroad: int = 0
	var ticks: int = 0
	var nitros: int = 0
	for _tick: int in range(MAX_TICKS):
		var events: int = CarSim.step(state, driver.sample(DT), stats, model, DT)
		ticks += 1
		if events & CarSim.EVENT_NITRO != 0:
			nitros += 1
		if state.offroad:
			offroad += 1
		if state.lap >= 1:
			break
	return {"lap": state.lap, "ticks": ticks, "offroad": offroad, "z": state.z, "nitros": nitros}


func test_completes_a_lap_on_every_track_mostly_on_the_road() -> void:
	for track: TrackDef in Catalog.tracks():
		var run: Dictionary = _drive(track.id, 7)
		assert_int(int(run["lap"])).override_failure_message(str(track.id)).is_greater_equal(1)
		assert_float(float(run["offroad"]) / float(run["ticks"])).is_less(OFFROAD_LIMIT)


func test_same_seed_drives_the_same_line() -> void:
	var a: Dictionary = _drive(&"sunset_city", 11)
	var b: Dictionary = _drive(&"sunset_city", 11)
	assert_int(int(a["ticks"])).is_equal(int(b["ticks"]))
	assert_float(float(a["z"])).is_equal(float(b["z"]))


func test_jumps_a_slower_car_in_its_lane() -> void:
	var model: TrackModel = TrackModel.new(Catalog.track(&"coast"))
	var state: CarState = CarState.new()
	state.speed = 9000.0
	state.z = 2000.0
	var slow: CarState = CarState.new()
	slow.z = state.z + Balance.value(&"car_length") * 2.0
	slow.speed = 2000.0
	var driver: AiDriver = AiDriver.new()
	driver.setup(model, 1.0, 1, 0)
	driver.bind(state, Catalog.stats_for(&"vortex", {}))
	driver.set_others([state, slow])
	var input: DriverInput = driver.sample(DT)
	assert_bool(input.jump).is_true()
	assert_float(input.throttle).is_equal(1.0)
