extends GdUnitTestSuite
## Host and client RaceSync over real ENet (port 0) attached to fake races that implement the
## duck-typed hooks of docs/ARCHITECTURE.md "Race scene contract". Bounded waits only.

const TIMEOUT_MSEC: int = 2000
const SETTLE_SEC: float = 0.2
const LOCALHOST: String = "127.0.0.1"
const SESSION_NODE: String = "Session"
const RACE_NODE: String = "Race"
const BOGUS_ID: int = 999
const RACE_TIME: float = 3.5
const FINISH_PLACE: int = 1
const FINISH_TIME: float = 42.25
const PENALTY: StringName = &"bump"


class FakeRace:
	extends Node
	signal local_state_updated(id: int, packed: PackedFloat32Array)
	signal penalty_decided(id: int, kind: StringName, data: Dictionary)
	var race_time: float = 0.0
	var results: Array[Dictionary] = []
	var remote_states: Dictionary = {}
	var penalties: Array[Dictionary] = []
	var phases: Array[Dictionary] = []
	var finishes: Array[Dictionary] = []
	var authority_calls: Array[bool] = []
	var _countdown_left: float = 2.25

	func set_remote_state(id: int, packed: PackedFloat32Array) -> void:
		remote_states[id] = packed

	func apply_penalty(id: int, kind: StringName, data: Dictionary) -> void:
		penalties.append({"id": id, "kind": kind, "data": data})

	func force_results(entries: Array[Dictionary]) -> void:
		results = entries

	func set_authority(is_host: bool) -> void:
		authority_calls.append(is_host)

	func force_phase(phase: StringName, time: float) -> void:
		phases.append({"phase": phase, "time": time})

	func force_finish(id: int, place: int, time: float) -> void:
		finishes.append({"id": id, "place": place, "time": time})


var _roots: Array[Node] = []
var _host: NetSessionService = null
var _client: NetSessionService = null
var _host_race: FakeRace = null
var _client_race: FakeRace = null
var _host_sync: RaceSync = null
var _client_sync: RaceSync = null


func before_test() -> void:
	_host = _session("Host")
	_client = _session("Client")
	_host_race = _race(_roots[0])
	_client_race = _race(_roots[1])
	_host_sync = _host_race.get_node(String(RaceSync.NODE_NAME))
	_client_sync = _client_race.get_node(String(RaceSync.NODE_NAME))
	await _pair()
	_host_sync.attach(_host_race)
	_client_sync.attach(_client_race)


func after_test() -> void:
	AudioDirector.stop_all()
	_host_sync.detach()
	_client_sync.detach()
	for root: Node in _roots:
		var session: NetSessionService = root.get_node(SESSION_NODE)
		session.leave()
		get_tree().set_multiplayer(null, root.get_path())
		root.queue_free()
	_roots.clear()
	await get_tree().process_frame


func _session(label: String) -> NetSessionService:
	var root: Node = Node.new()
	root.name = label
	get_tree().root.add_child(root)
	_roots.append(root)
	get_tree().set_multiplayer(SceneMultiplayer.new(), root.get_path())
	var session: NetSessionService = NetSessionService.new()
	session.name = SESSION_NODE
	root.add_child(session)
	return session


func _race(root: Node) -> FakeRace:
	var race: FakeRace = FakeRace.new()
	race.name = RACE_NODE
	root.add_child(race)
	race.add_child(RaceSync.new())
	return race


func _wait_until(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await get_tree().physics_frame
	return bool(predicate.call())


func _pair() -> void:
	assert_int(_host.host(0, LobbyProfile.new())).is_equal(OK)
	assert_int(_client.join(LOCALHOST, _host.bound_port(), LobbyProfile.new())).is_equal(OK)
	var paired: bool = await _wait_until(
		func() -> bool: return _host.seats().size() == 2 and _client.seats().size() == 2
	)
	assert_bool(paired).override_failure_message("host and client did not pair").is_true()


func _sample_state() -> CarState:
	var state: CarState = CarState.new()
	state.z = 1234.5
	state.x = 0.25
	state.speed = 9000.0
	state.altitude = 50.0
	state.vertical_speed = -3.0
	state.airborne = true
	state.nitro = 0.5
	state.nitro_time_left = 1.25
	state.thrusters = 0.75
	state.integrity = 66.0
	state.lap = 1
	state.steer_visual = -0.5
	return state


func test_attach_tells_each_race_who_is_authority() -> void:
	assert_array(_host_race.authority_calls).contains_exactly([true])
	assert_array(_client_race.authority_calls).contains_exactly([false])
	assert_bool(_host_sync.is_authority()).is_true()
	assert_bool(_client_sync.is_authority()).is_false()


func test_client_state_reaches_the_host_with_the_same_values() -> void:
	var client_id: int = _client.local_peer_id()
	var packed: PackedFloat32Array = _sample_state().to_packed()
	_client_race.local_state_updated.emit(client_id, packed)
	var received: bool = await _wait_until(
		func() -> bool: return _host_race.remote_states.has(client_id)
	)
	assert_bool(received).override_failure_message("host never got the state").is_true()
	var remote: PackedFloat32Array = _host_race.remote_states[client_id]
	assert_int(remote.size()).is_equal(CarState.FIELD_COUNT)
	for index: int in range(CarState.FIELD_COUNT):
		assert_float(remote[index]).is_equal_approx(packed[index], 0.0001)
	var mirrored: CarState = CarState.new()
	mirrored.from_packed(remote)
	assert_float(mirrored.z).is_equal_approx(1234.5, 0.0001)
	assert_int(mirrored.lap).is_equal(1)
	assert_bool(mirrored.airborne).is_true()
	assert_array(_host_sync.remote_ids()).contains_exactly([client_id])
	assert_int(_host_sync.interpolated_state(client_id).size()).is_equal(CarState.FIELD_COUNT)
	assert_bool(_client_race.remote_states.has(client_id)).is_false()


func test_remote_states_interpolate_between_packets() -> void:
	var client_id: int = _client.local_peer_id()
	var first: PackedFloat32Array = _sample_state().to_packed()
	_client_race.local_state_updated.emit(client_id, first)
	var got_first: bool = await _wait_until(
		func() -> bool: return _host_race.remote_states.has(client_id)
	)
	assert_bool(got_first).is_true()
	var second: CarState = _sample_state()
	second.z = first[RaceSync.PACKED_Z] + 400.0
	second.x = -0.5
	_client_race.local_state_updated.emit(client_id, second.to_packed())
	var moved: bool = await _wait_until(
		func() -> bool:
			var z: float = _host_race.remote_states[client_id][RaceSync.PACKED_Z]
			return z > first[RaceSync.PACKED_Z] and z < second.z
	)
	assert_bool(moved).override_failure_message("no intermediate z observed").is_true()
	var settled: bool = await _wait_until(
		func() -> bool:
			var z: float = _host_race.remote_states[client_id][RaceSync.PACKED_Z]
			return is_equal_approx(z, second.z)
	)
	assert_bool(settled).override_failure_message("z never reached the target").is_true()
	assert_float(_host_race.remote_states[client_id][RaceSync.PACKED_X]).is_equal_approx(
		-0.5, 0.0001
	)


func test_peer_may_only_publish_its_own_id() -> void:
	var packed: PackedFloat32Array = _sample_state().to_packed()
	_client_race.local_state_updated.emit(BOGUS_ID, packed)
	_client_sync._rpc_state.rpc(BOGUS_ID, packed)
	await get_tree().create_timer(SETTLE_SEC).timeout
	assert_bool(_host_race.remote_states.has(BOGUS_ID)).is_false()
	assert_array(_host_sync.remote_ids()).is_empty()


func test_host_penalty_is_relayed_to_the_owning_peer_only() -> void:
	var client_id: int = _client.local_peer_id()
	_host_race.penalty_decided.emit(client_id, PENALTY, {"push": -0.15, "speed_ratio": 0.8})
	var relayed: bool = await _wait_until(func() -> bool: return _client_race.penalties.size() == 1)
	assert_bool(relayed).override_failure_message("penalty not relayed").is_true()
	assert_int(_client_race.penalties[0]["id"]).is_equal(client_id)
	assert_str(String(_client_race.penalties[0]["kind"])).is_equal(String(PENALTY))
	assert_dict(_client_race.penalties[0]["data"]).is_equal({"push": -0.15, "speed_ratio": 0.8})
	_host_race.penalty_decided.emit(
		Constants.HOST_PEER_ID, PENALTY, {"push": -0.15, "speed_ratio": 0.8}
	)
	_client_race.penalty_decided.emit(client_id, PENALTY, {"push": -0.15, "speed_ratio": 0.8})
	await get_tree().create_timer(SETTLE_SEC).timeout
	assert_int(_client_race.penalties.size()).is_equal(1)
	assert_int(_host_race.penalties.size()).is_equal(0)


func test_host_phase_countdown_and_finish_propagate() -> void:
	var client_id: int = _client.local_peer_id()
	_host_race.race_time = RACE_TIME
	RaceBus.race_phase_changed.emit(Constants.PHASE_RACING)
	RaceBus.countdown_tick.emit(1)
	RaceBus.car_finished.emit(client_id, FINISH_PLACE, FINISH_TIME)
	var delivered: bool = await _wait_until(
		func() -> bool: return _client_race.phases.size() == 2 and _client_race.finishes.size() == 1
	)
	assert_bool(delivered).override_failure_message("phase/finish not delivered").is_true()
	assert_str(String(_client_race.phases[0]["phase"])).is_equal(String(Constants.PHASE_RACING))
	assert_float(_client_race.phases[0]["time"]).is_equal_approx(RACE_TIME, 0.0001)
	assert_str(String(_client_race.phases[1]["phase"])).is_equal(String(Constants.PHASE_COUNTDOWN))
	assert_float(_client_race.phases[1]["time"]).is_equal(2.25)
	assert_int(_client_race.finishes[0]["id"]).is_equal(client_id)
	assert_int(_client_race.finishes[0]["place"]).is_equal(FINISH_PLACE)
	assert_float(_client_race.finishes[0]["time"]).is_equal_approx(FINISH_TIME, 0.0001)
	assert_int(_host_race.phases.size()).is_equal(0)


func test_results_and_crush_feedback_relay() -> void:
	var entries: Array[Dictionary] = [{"id": 1, "place": 1, "time": 42.0}]
	var landed: Array[int] = []
	var capture: Callable = func(id: int, hard: bool) -> void:
		if hard:
			landed.append(id)
	RaceBus.car_landed.connect(capture)
	RaceBus.race_finished.emit(entries)
	RaceBus.car_crushed.emit(1, _client.local_peer_id())
	var delivered: bool = await _wait_until(
		func() -> bool: return _client_race.results.size() == 1 and landed.size() == 1
	)
	RaceBus.car_landed.disconnect(capture)
	assert_bool(delivered).is_true()
	assert_array(_client_race.results).is_equal(entries)
	assert_array(landed).contains_exactly([1])
	assert_array(_client_race.penalties).is_empty()
