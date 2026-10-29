class_name NetSessionService
extends Node
## Autoload `NetSession`: owns the ENet peer and the authoritative lobby (docs/NET_API.md).
## The host (peer 1, seat 0) keeps the seat list and replicates it with a reliable RPC on
## every change; clients send their profile on connect and ask the host for changes.
## Tests instantiate extra copies under scene-tree branches bound to their own
## SceneMultiplayer (SceneTree.set_multiplayer): the API is resolved from the node path
## when host()/join() run, so every peer must keep this node at the same relative path.

signal seats_changed(seats: Array)
signal race_requested(track_id: StringName, seed: int)
signal connection_failed(reason: String)
signal disconnected
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

const REASON_ROOM_FULL: String = "room_full"
const REASON_KICKED: String = "kicked"
const REASON_UNREACHABLE: String = "unreachable"
const REASON_HOST_LEFT: String = "host_left"
const KEY_ID: String = "id"
const KEY_IS_LOCAL: String = "is_local"
const NO_PORT: int = 0
const NO_BANDWIDTH_LIMIT: int = 0
const DISCONNECT_DATA: int = 0
const HOST_SEAT: int = 0
const NO_SENDER: int = 0

## Seats the host accepts, host included. Tests lower it to exercise rejection.
var max_seats: int = Constants.MAX_PLAYERS
## Why the last session ended or failed (a REASON_* constant; empty after a voluntary leave).
var last_reason: String = ""

var _api: MultiplayerAPI = null
var _enet: ENetMultiplayerPeer = null
var _hosting: bool = false
var _admitted: bool = false
var _profile: LobbyProfile = LobbyProfile.new()
var _seats: Array[LobbySeat] = []


## Port 0 picks an ephemeral port; read it back with bound_port(). Host is peer 1, seat 0.
func host(port: int, profile: LobbyProfile) -> Error:
	if _enet != null:
		return ERR_ALREADY_IN_USE
	var enet: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = enet.create_server(port, Constants.MAX_PLAYERS - 1)
	if err != OK:
		return err
	_lift_bandwidth_cap(enet)
	_bind(enet, profile, true)
	_admitted = true
	var first: Array[LobbySeat] = [LobbySeat.make(Constants.HOST_PEER_ID, HOST_SEAT, _profile)]
	_commit_seats(first)
	return OK


## Connects to a host; the outcome arrives as seats_changed (admitted) or connection_failed.
func join(address: String, port: int, profile: LobbyProfile) -> Error:
	if _enet != null:
		return ERR_ALREADY_IN_USE
	var ip: String = address if address.is_valid_ip_address() else IP.resolve_hostname(address)
	if not ip.is_valid_ip_address():
		return ERR_CANT_RESOLVE
	var enet: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = enet.create_client(ip, port)
	if err != OK:
		return err
	_lift_bandwidth_cap(enet)
	_bind(enet, profile, false)
	return OK


## Closes the session. A client tells the host first so its seat is freed at once.
## Voluntary leaves do not emit disconnected; losing the host or being kicked does.
func leave() -> void:
	if _enet == null:
		return
	if _can_reach_host():
		_rpc_bye.rpc_id(Constants.HOST_PEER_ID)
		_enet.host.flush()
	last_reason = ""
	_teardown()


## Offline counts as hosting: single player is a host with no clients.
func is_host() -> bool:
	return _enet == null or _hosting


## True once the host admitted us (clients) or since host() succeeded (host).
func is_online() -> bool:
	return _enet != null and _admitted


func local_peer_id() -> int:
	if _enet == null:
		return Constants.HOST_PEER_ID
	return _api.get_unique_id()


## Port the host listens on; needed when host() was given port 0. 0 when not hosting.
func bound_port() -> int:
	if _enet == null or not _hosting:
		return NO_PORT
	return _enet.host.get_local_port()


## Copy of the seat list ordered by seat index (host first).
func seats() -> Array[LobbySeat]:
	return _seats.duplicate()


func local_seat() -> LobbySeat:
	return _seat_of(local_peer_id())


func set_ready(ready: bool) -> void:
	if _hosting:
		_seat_of(Constants.HOST_PEER_ID).ready = ready
		_commit_seats(_seats)
	elif _can_reach_host():
		_rpc_set_ready.rpc_id(Constants.HOST_PEER_ID, ready)


## Name, car, paint, tiers or integrity changed. Before admission it is sent with the hello.
func set_profile(profile: LobbyProfile) -> void:
	_profile = profile if profile != null else LobbyProfile.new()
	if _hosting:
		_seat_of(Constants.HOST_PEER_ID).apply_profile(_profile)
		_commit_seats(_seats)
	elif _can_reach_host():
		_rpc_update_profile.rpc_id(Constants.HOST_PEER_ID, _profile.to_dictionary())


## Host only. Draws the run seed, tells every peer and emits race_requested locally too.
func request_start(track_id: StringName) -> void:
	if not is_host():
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var race_seed: int = rng.randi()
	if _has_peers():
		_rpc_race_requested.rpc(track_id, race_seed)
	race_requested.emit(track_id, race_seed)


## Host only. Tells the peer why, closes its connection and frees its seat.
func kick(peer_id: int) -> void:
	if not _hosting or peer_id == Constants.HOST_PEER_ID:
		return
	_reject(peer_id, REASON_KICKED)
	_remove_seat(peer_id)


## One entry per seat, in seat order, for the UI to build RaceConfig participants from:
## id (peer id), name, car_id, paint, tiers, integrity, is_local.
func participants_data() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var local_id: int = local_peer_id()
	for seat: LobbySeat in _seats:
		var entry: Dictionary = seat.profile().to_dictionary()
		entry[KEY_ID] = seat.peer_id
		entry[KEY_IS_LOCAL] = seat.peer_id == local_id
		result.append(entry)
	return result


func _bind(enet: ENetMultiplayerPeer, profile: LobbyProfile, hosting: bool) -> void:
	_enet = enet
	_hosting = hosting
	_admitted = false
	_profile = profile if profile != null else LobbyProfile.new()
	last_reason = ""
	_api = multiplayer
	_api.peer_connected.connect(_on_peer_connected)
	_api.peer_disconnected.connect(_on_peer_disconnected)
	_api.connected_to_server.connect(_on_connected_to_server)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)
	_api.multiplayer_peer = enet


func _teardown() -> void:
	if _enet == null:
		return
	_api.peer_connected.disconnect(_on_peer_connected)
	_api.peer_disconnected.disconnect(_on_peer_disconnected)
	_api.connected_to_server.disconnect(_on_connected_to_server)
	_api.connection_failed.disconnect(_on_connection_failed)
	_api.server_disconnected.disconnect(_on_server_disconnected)
	_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_enet.close()
	_enet = null
	_hosting = false
	_admitted = false
	var empty: Array[LobbySeat] = []
	_commit_seats(empty)


## Client side: the session ended for an external reason. Emits connection_failed before
## admission and disconnected after it. Deferred so the peer is never swapped mid-poll.
func _end_session(reason: String) -> void:
	if _enet == null:
		return
	var admitted: bool = _admitted
	last_reason = reason
	_teardown()
	if admitted:
		disconnected.emit()
	else:
		connection_failed.emit(reason)


## Godot 4.7.2 forwards the channel count as the inbound bandwidth cap (bytes/s) when the
## peer is created; zero lifts the cap. Re-check against the engine source when upgrading.
static func _lift_bandwidth_cap(enet: ENetMultiplayerPeer) -> void:
	enet.host.bandwidth_limit(NO_BANDWIDTH_LIMIT, NO_BANDWIDTH_LIMIT)


func _has_peers() -> bool:
	return _enet != null and _api.get_peers().size() > 0


func _can_reach_host() -> bool:
	return _enet != null and not _hosting and _api.get_peers().has(Constants.HOST_PEER_ID)


func _seat_of(peer_id: int) -> LobbySeat:
	for seat: LobbySeat in _seats:
		if seat.peer_id == peer_id:
			return seat
	return null


func _free_seat_index() -> int:
	for index: int in range(max_seats):
		var taken: bool = false
		for seat: LobbySeat in _seats:
			taken = taken or seat.seat == index
		if not taken:
			return index
	return Constants.INVALID_ID


## Replaces the seat list, emits peer_joined/peer_left for the difference and seats_changed
## always; the host also replicates the new list to every client.
func _commit_seats(new_seats: Array[LobbySeat]) -> void:
	var before: Array[int] = _peer_ids(_seats)
	var after: Array[int] = _peer_ids(new_seats)
	_seats = new_seats.duplicate()
	_seats.sort_custom(func(a: LobbySeat, b: LobbySeat) -> bool: return a.seat < b.seat)
	for peer_id: int in before:
		if not after.has(peer_id):
			peer_left.emit(peer_id)
	for peer_id: int in after:
		if not before.has(peer_id):
			peer_joined.emit(peer_id)
	if _hosting and _has_peers():
		_rpc_seats.rpc(_seats_data())
	seats_changed.emit(seats())


static func _peer_ids(list: Array[LobbySeat]) -> Array[int]:
	var ids: Array[int] = []
	for seat: LobbySeat in list:
		ids.append(seat.peer_id)
	return ids


func _seats_data() -> Array:
	var data: Array = []
	for seat: LobbySeat in _seats:
		data.append(seat.to_dictionary())
	return data


func _add_seat(peer_id: int, profile: LobbyProfile) -> void:
	var index: int = _free_seat_index()
	if index == Constants.INVALID_ID:
		_reject(peer_id, REASON_ROOM_FULL)
		return
	var new_seats: Array[LobbySeat] = _seats.duplicate()
	new_seats.append(LobbySeat.make(peer_id, index, profile))
	_commit_seats(new_seats)


func _remove_seat(peer_id: int) -> void:
	if _seat_of(peer_id) == null:
		return
	var new_seats: Array[LobbySeat] = []
	for seat: LobbySeat in _seats:
		if seat.peer_id != peer_id:
			new_seats.append(seat)
	_commit_seats(new_seats)


## Host: tells a connected peer why it is dropped, then closes it once that message is out.
func _reject(peer_id: int, reason: String) -> void:
	if not _api.get_peers().has(peer_id):
		return
	_rpc_rejected.rpc_id(peer_id, reason)
	_enet.get_peer(peer_id).peer_disconnect_later(DISCONNECT_DATA)


func _sender_seat() -> LobbySeat:
	if not _hosting:
		return null
	return _seat_of(_api.get_remote_sender_id())


func _on_peer_connected(peer_id: int) -> void:
	if _hosting and _seats.size() >= max_seats:
		_reject(peer_id, REASON_ROOM_FULL)


func _on_peer_disconnected(peer_id: int) -> void:
	if _hosting:
		_remove_seat(peer_id)


func _on_connected_to_server() -> void:
	_rpc_hello.rpc_id(Constants.HOST_PEER_ID, _profile.to_dictionary())


func _on_connection_failed() -> void:
	_end_session.call_deferred(REASON_UNREACHABLE)


func _on_server_disconnected() -> void:
	_end_session.call_deferred(REASON_HOST_LEFT)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(profile: Dictionary) -> void:
	var sender: int = _api.get_remote_sender_id()
	if not _hosting or sender == NO_SENDER:
		return
	var seat: LobbySeat = _seat_of(sender)
	if seat != null:
		seat.apply_profile(LobbyProfile.from_dictionary(profile))
		_commit_seats(_seats)
	elif _seats.size() < max_seats:
		_add_seat(sender, LobbyProfile.from_dictionary(profile))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_update_profile(profile: Dictionary) -> void:
	var seat: LobbySeat = _sender_seat()
	if seat == null:
		return
	seat.apply_profile(LobbyProfile.from_dictionary(profile))
	_commit_seats(_seats)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_ready(ready: bool) -> void:
	var seat: LobbySeat = _sender_seat()
	if seat == null:
		return
	seat.ready = ready
	_commit_seats(_seats)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_bye() -> void:
	if _hosting:
		_remove_seat(_api.get_remote_sender_id())


@rpc("authority", "call_remote", "reliable")
func _rpc_seats(data: Array) -> void:
	if _hosting:
		return
	var new_seats: Array[LobbySeat] = []
	for entry: Variant in data:
		if entry is Dictionary:
			new_seats.append(LobbySeat.from_dictionary(entry))
	_admitted = true
	_commit_seats(new_seats)


@rpc("authority", "call_remote", "reliable")
func _rpc_race_requested(track_id: StringName, race_seed: int) -> void:
	if not _hosting:
		race_requested.emit(track_id, race_seed)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	if not _hosting:
		_end_session.call_deferred(reason)
