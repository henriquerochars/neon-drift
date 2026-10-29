class_name LobbyAdapter
extends RefCounted
## Every NetSession call the UI makes, in one place (docs/NET_API.md). Each call is guarded
## with has_method / has_signal so the UI runs (and its tests pass) against the current
## NetSession stub; the net lane fills the methods in without touching the UI.

const PROFILE_SCRIPT_PATH: String = "res://src/net/lobby_profile.gd"
const RACE_SYNC_PATH: String = "res://src/net/race_sync.gd"
const SYNC_NODE_NAME: String = "RaceSync"
const FULL: float = 100.0
const SEAT_FIELDS: Array[StringName] = [&"peer_id", &"name", &"car_id", &"paint", &"ready"]


static func supported() -> bool:
	return NetSession.has_method(&"host") and NetSession.has_method(&"join")


static func is_online() -> bool:
	return NetSession.is_online()


static func is_host() -> bool:
	return NetSession.is_host()


static func local_peer_id() -> int:
	return NetSession.local_peer_id()


## NetSession.host(port, profile). Returns OK, ERR_UNAVAILABLE on the stub or the net error.
static func host(port: int, player_name: String, car_id: StringName, paint: int) -> int:
	if not supported():
		return ERR_UNAVAILABLE
	return int(NetSession.call(&"host", port, make_profile(player_name, car_id, paint)))


## NetSession.join(address, port, profile).
static func join(
	address: String, port: int, player_name: String, car_id: StringName, paint: int
) -> int:
	if not supported():
		return ERR_UNAVAILABLE
	return int(NetSession.call(&"join", address, port, make_profile(player_name, car_id, paint)))


static func leave() -> void:
	if NetSession.has_method(&"leave"):
		NetSession.call(&"leave")


static func set_ready(ready: bool) -> void:
	if NetSession.has_method(&"set_ready"):
		NetSession.call(&"set_ready", ready)


static func set_car(car_id: StringName, paint: int) -> void:
	if NetSession.has_method(&"set_profile"):
		NetSession.call(&"set_profile", make_profile(GameSettings.player_name, car_id, paint))


static func request_start(track_id: StringName) -> void:
	if NetSession.has_method(&"request_start"):
		NetSession.call(&"request_start", track_id)


## NetSession.seats() normalised to dictionaries {peer_id, name, car_id, paint, ready}.
static func seats() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not NetSession.has_method(&"seats"):
		return result
	var raw: Variant = NetSession.call(&"seats")
	if not raw is Array:
		return result
	for seat: Variant in raw as Array:
		if seat is Object:
			result.append(_seat_dictionary(seat as Object))
		elif seat is Dictionary:
			result.append(seat as Dictionary)
	return result


## NetSession.participants_data(): [{id, name, car_id, paint, tiers, integrity, is_local}].
## Falls back to seats() plus the local profile until the net lane provides it.
static func participants_data() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if NetSession.has_method(&"participants_data"):
		var raw: Variant = NetSession.call(&"participants_data")
		if raw is Array:
			result.assign(raw)
		return result
	for seat: Dictionary in seats():
		var peer: int = int(seat.get("peer_id", Constants.INVALID_ID))
		var is_local: bool = peer == local_peer_id()
		var car_id: StringName = StringName(str(seat.get("car_id", PlayerProfile.DEFAULT_CAR)))
		var data: Dictionary = {
			"id": peer,
			"name": str(seat.get("name", "")),
			"car_id": car_id,
			"paint": int(seat.get("paint", 0)),
			"tiers": PlayerProfile.parts.get(car_id, {}) if is_local else {},
			"integrity": PlayerProfile.integrity_of(car_id) if is_local else FULL,
			"is_local": is_local,
		}
		result.append(data)
	return result


## RaceConfig for the race NetSession.race_requested announced.
static func build_race_config(track_id: StringName, seed: int) -> RaceConfig:
	var config: RaceConfig = RaceConfig.new()
	config.track_id = track_id
	config.seed = seed
	config.online = true
	var track: TrackDef = Catalog.track(track_id)
	if track != null:
		config.laps = track.laps
	for data: Dictionary in participants_data():
		var is_local: bool = bool(data.get("is_local", false))
		var participant: RaceConfig.Participant = config.add_participant(
			int(data.get("id", Constants.INVALID_ID)),
			str(data.get("name", "")),
			StringName(str(data.get("car_id", PlayerProfile.DEFAULT_CAR))),
			RaceConfig.KIND_LOCAL if is_local else RaceConfig.KIND_REMOTE,
			int(data.get("paint", 0))
		)
		participant.tiers = (data.get("tiers", {}) as Dictionary).duplicate()
		participant.integrity = float(data.get("integrity", PlayerProfile.FULL_INTEGRITY))
	return config


## Connects `handlers` (signal name -> Callable) to the NetSession signals that exist.
static func connect_signals(handlers: Dictionary) -> void:
	for signal_name: StringName in handlers.keys():
		var callable: Callable = handlers[signal_name]
		if (
			NetSession.has_signal(signal_name)
			and not NetSession.is_connected(signal_name, callable)
		):
			NetSession.connect(signal_name, callable)


static func disconnect_signals(handlers: Dictionary) -> void:
	for signal_name: StringName in handlers.keys():
		var callable: Callable = handlers[signal_name]
		if NetSession.has_signal(signal_name) and NetSession.is_connected(signal_name, callable):
			NetSession.disconnect(signal_name, callable)


## Adds a RaceSync child to the race scene and calls attach(race). Null until the net lane lands.
static func attach_sync(race: Node) -> Node:
	if race == null or not ResourceLoader.exists(RACE_SYNC_PATH):
		return null
	var script: GDScript = load(RACE_SYNC_PATH) as GDScript
	if script == null:
		return null
	var sync: Node = script.new() as Node
	if sync == null:
		return null
	sync.name = SYNC_NODE_NAME
	race.add_child(sync)
	if sync.has_method(&"attach"):
		sync.call(&"attach", race)
	return sync


## LobbyProfile resource (src/net/lobby_profile.gd) filled by property name; null on the stub.
static func make_profile(player_name: String, car_id: StringName, paint: int) -> Resource:
	if not ResourceLoader.exists(PROFILE_SCRIPT_PATH):
		return null
	var script: GDScript = load(PROFILE_SCRIPT_PATH) as GDScript
	if script == null:
		return null
	var profile: Resource = script.new() as Resource
	if profile == null:
		return null
	profile.set(&"name", player_name)
	profile.set(&"car_id", car_id)
	profile.set(&"paint", paint)
	profile.set(&"tiers", (PlayerProfile.parts.get(car_id, {}) as Dictionary).duplicate())
	profile.set(&"integrity", PlayerProfile.integrity_of(car_id))
	return profile


static func _seat_dictionary(seat: Object) -> Dictionary:
	var result: Dictionary = {}
	for field: StringName in SEAT_FIELDS:
		result[String(field)] = seat.get(field)
	return result
