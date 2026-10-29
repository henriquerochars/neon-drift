extends GdUnitTestSuite
## Host and client NetSession in one process: two scene-tree branches, each bound to its own
## SceneMultiplayer, real ENet on 127.0.0.1 and an ephemeral port (port 0). Every wait is
## bounded by TIMEOUT_MSEC so a broken transport fails instead of hanging.

const TIMEOUT_MSEC: int = 2000
const SETTLE_SEC: float = 0.2
const POLL_SEC: float = 0.02
const LOCALHOST: String = "127.0.0.1"
const SESSION_NODE: String = "Session"
const HOST_NAME: String = "HOSTY"
const CLIENT_NAME: String = "GUEST"
const CLIENT_CAR: StringName = &"hornet"
const CLIENT_PAINT: int = 2
const CLIENT_TIER: int = 1
const CLIENT_INTEGRITY: float = 80.0
const TRACK: StringName = &"coast"

var _roots: Array[Node] = []
var _host: NetSessionService = null
var _client: NetSessionService = null
var _host_requests: Array[Dictionary] = []
var _client_requests: Array[Dictionary] = []
var _client_failures: Array[String] = []
var _client_disconnects: int = 0
var _host_left: Array[int] = []


func before_test() -> void:
	_host = _session("Host")
	_client = _session("Client")
	_host_requests.clear()
	_client_requests.clear()
	_client_failures.clear()
	_client_disconnects = 0
	_host_left.clear()
	_host.race_requested.connect(
		func(track_id: StringName, race_seed: int) -> void:
			_host_requests.append({"track": track_id, "seed": race_seed})
	)
	_client.race_requested.connect(
		func(track_id: StringName, race_seed: int) -> void:
			_client_requests.append({"track": track_id, "seed": race_seed})
	)
	_client.connection_failed.connect(func(reason: String) -> void: _client_failures.append(reason))
	_client.disconnected.connect(func() -> void: _client_disconnects += 1)
	_host.peer_left.connect(func(peer_id: int) -> void: _host_left.append(peer_id))


func after_test() -> void:
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


func _profile(player_name: String) -> LobbyProfile:
	return LobbyProfile.make(
		player_name, CLIENT_CAR, CLIENT_PAINT, {&"engine": CLIENT_TIER}, CLIENT_INTEGRITY
	)


## Polls until the predicate holds or TIMEOUT_MSEC passed; returns the final verdict.
func _wait_until(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await get_tree().create_timer(POLL_SEC).timeout
	return bool(predicate.call())


func _pair() -> void:
	assert_int(_host.host(0, _profile(HOST_NAME))).is_equal(OK)
	assert_int(_host.bound_port()).is_greater(0)
	var err: Error = _client.join(LOCALHOST, _host.bound_port(), _profile(CLIENT_NAME))
	assert_int(err).is_equal(OK)
	var paired: bool = await _wait_until(
		func() -> bool: return _host.seats().size() == 2 and _client.seats().size() == 2
	)
	assert_bool(paired).override_failure_message("host and client did not pair").is_true()


func _names(session: NetSessionService) -> Array[String]:
	var names: Array[String] = []
	for seat: LobbySeat in session.seats():
		names.append(seat.name)
	return names


func test_host_binds_ephemeral_port_and_takes_seat_zero() -> void:
	assert_bool(_host.is_online()).is_false()
	assert_bool(_host.is_host()).is_true()
	assert_int(_host.host(0, _profile(HOST_NAME))).is_equal(OK)
	assert_int(_host.bound_port()).is_greater(0)
	assert_bool(_host.is_online()).is_true()
	assert_bool(_host.is_host()).is_true()
	assert_int(_host.local_peer_id()).is_equal(Constants.HOST_PEER_ID)
	var seats: Array[LobbySeat] = _host.seats()
	assert_int(seats.size()).is_equal(1)
	assert_int(seats[0].peer_id).is_equal(Constants.HOST_PEER_ID)
	assert_int(seats[0].seat).is_equal(0)
	assert_str(seats[0].name).is_equal(HOST_NAME)
	assert_int(_host.host(0, _profile(HOST_NAME))).is_equal(ERR_ALREADY_IN_USE)


func test_client_joins_and_both_sides_see_two_named_seats() -> void:
	await _pair()
	assert_array(_names(_host)).contains_exactly([HOST_NAME, CLIENT_NAME])
	assert_array(_names(_client)).contains_exactly([HOST_NAME, CLIENT_NAME])
	assert_bool(_client.is_host()).is_false()
	assert_bool(_client.is_online()).is_true()
	var client_id: int = _client.local_peer_id()
	assert_int(client_id).is_not_equal(Constants.HOST_PEER_ID)
	assert_int(_host.seats()[1].peer_id).is_equal(client_id)
	assert_int(_client.local_seat().seat).is_equal(1)
	var guest: Dictionary = _host.participants_data()[1]
	assert_int(guest[NetSessionService.KEY_ID]).is_equal(client_id)
	assert_bool(guest[NetSessionService.KEY_IS_LOCAL]).is_false()
	assert_str(String(guest[LobbyProfile.KEY_CAR_ID])).is_equal(String(CLIENT_CAR))
	assert_int(guest[LobbyProfile.KEY_PAINT]).is_equal(CLIENT_PAINT)
	assert_int(guest[LobbyProfile.KEY_TIERS][&"engine"]).is_equal(CLIENT_TIER)
	assert_float(guest[LobbyProfile.KEY_INTEGRITY]).is_equal(CLIENT_INTEGRITY)
	assert_bool(_client.participants_data()[1][NetSessionService.KEY_IS_LOCAL]).is_true()


func test_client_ready_and_profile_changes_reach_the_host() -> void:
	await _pair()
	var client_id: int = _client.local_peer_id()
	_client.set_ready(true)
	var ready: bool = await _wait_until(
		func() -> bool:
			var seat: LobbySeat = _host.seats()[1]
			return seat.ready and _client.local_seat().ready
	)
	assert_bool(ready).override_failure_message("ready flag did not propagate").is_true()
	_client.set_profile(LobbyProfile.make("NEWNAME", &"bruiser", 5, {}, 55.0))
	var renamed: bool = await _wait_until(func() -> bool: return _host.seats()[1].name == "NEWNAME")
	assert_bool(renamed).override_failure_message("profile did not propagate").is_true()
	assert_str(_host.seats()[1].car_id).is_equal("bruiser")
	assert_int(_host.seats()[1].peer_id).is_equal(client_id)
	assert_bool(_host.seats()[1].ready).is_true()


func test_extra_peer_is_rejected_when_room_is_full() -> void:
	_host.max_seats = 1
	assert_int(_host.host(0, _profile(HOST_NAME))).is_equal(OK)
	var err: Error = _client.join(LOCALHOST, _host.bound_port(), _profile(CLIENT_NAME))
	assert_int(err).is_equal(OK)
	var rejected: bool = await _wait_until(
		func() -> bool: return not _client_failures.is_empty() or _client_disconnects > 0
	)
	assert_bool(rejected).override_failure_message("client was not rejected").is_true()
	assert_array(_client_failures).contains_exactly([NetSessionService.REASON_ROOM_FULL])
	assert_int(_client_disconnects).is_equal(0)
	assert_bool(_client.is_online()).is_false()
	await get_tree().create_timer(SETTLE_SEC).timeout
	assert_int(_host.seats().size()).is_equal(1)


func test_request_start_gives_every_peer_the_same_seed() -> void:
	await _pair()
	_client.request_start(TRACK)
	_host.request_start(TRACK)
	var delivered: bool = await _wait_until(
		func() -> bool: return _host_requests.size() == 1 and _client_requests.size() == 1
	)
	assert_bool(delivered).override_failure_message("race_requested not delivered").is_true()
	assert_str(_host_requests[0]["track"]).is_equal(String(TRACK))
	assert_str(_client_requests[0]["track"]).is_equal(String(TRACK))
	assert_int(_client_requests[0]["seed"]).is_equal(_host_requests[0]["seed"])


func test_client_leave_frees_its_seat_on_the_host() -> void:
	await _pair()
	var client_id: int = _client.local_peer_id()
	_client.leave()
	assert_bool(_client.is_online()).is_false()
	assert_int(_client.seats().size()).is_equal(0)
	var freed: bool = await _wait_until(func() -> bool: return _host.seats().size() == 1)
	assert_bool(freed).override_failure_message("host kept the seat").is_true()
	assert_array(_host_left).contains_exactly([client_id])
	assert_int(_client_disconnects).is_equal(0)


func test_kick_drops_the_client() -> void:
	await _pair()
	_host.kick(_client.local_peer_id())
	assert_int(_host.seats().size()).is_equal(1)
	var kicked: bool = await _wait_until(func() -> bool: return _client_disconnects == 1)
	assert_bool(kicked).override_failure_message("kicked client not disconnected").is_true()
	assert_str(_client.last_reason).is_equal(NetSessionService.REASON_KICKED)
	assert_bool(_client.is_online()).is_false()


func test_host_leave_disconnects_the_client() -> void:
	await _pair()
	_host.leave()
	assert_bool(_host.is_online()).is_false()
	var dropped: bool = await _wait_until(func() -> bool: return _client_disconnects == 1)
	assert_bool(dropped).override_failure_message("client did not see host leave").is_true()
	assert_str(_client.last_reason).is_equal(NetSessionService.REASON_HOST_LEFT)
	assert_bool(_client.is_online()).is_false()
