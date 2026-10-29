class_name RaceSync
extends Node
## Replicates CarState between peers and relays the host's verdicts (docs/NET_API.md).
## The UI adds it under the race scene when NetSession.is_online() and calls attach(race).
## RPCs are routed by node path, so every peer must keep it at the same path; the node names
## itself NODE_NAME to help. Each peer publishes its own packed CarState at SEND_RATE_HZ
## (unreliable, ordered); remote states are interpolated (z, x, altitude) before reaching
## the race. The host relays penalties to the owning peer and broadcasts phase, countdown
## and finish order from the RaceBus signals its own race emits.

const NODE_NAME: StringName = &"RaceSync"
const SEND_RATE_HZ: float = 20.0
const SEND_INTERVAL: float = 1.0 / SEND_RATE_HZ
## A z jump at least this large between two packets is a lap wrap or a respawn: snap.
const Z_SNAP_DISTANCE: float = 5000.0
## Indices in CarState.to_packed().
const PACKED_Z: int = 0
const PACKED_X: int = 1
const PACKED_ALTITUDE: int = 3
const SIGNAL_LOCAL_STATE: StringName = &"local_state_updated"
const SIGNAL_PENALTY: StringName = &"penalty_decided"
const METHOD_SET_REMOTE: StringName = &"set_remote_state"
const METHOD_APPLY_PENALTY: StringName = &"apply_penalty"
const METHOD_SET_AUTHORITY: StringName = &"set_authority"
const METHOD_FORCE_PHASE: StringName = &"force_phase"
const METHOD_FORCE_FINISH: StringName = &"force_finish"
const PROPERTY_RACE_TIME: StringName = &"race_time"


class RemoteTrack:
	extends RefCounted
	## Last two received states and the interpolated one written to the race.
	var previous: PackedFloat32Array = PackedFloat32Array()
	var latest: PackedFloat32Array = PackedFloat32Array()
	var current: PackedFloat32Array = PackedFloat32Array()
	var elapsed: float = 0.0


static var _receiving: bool = false
var _race: Node = null
var _api: MultiplayerAPI = null
## participant id -> latest packed state waiting for the next send slot.
var _pending: Dictionary = {}
var _send_accumulator: float = 0.0
## peer id -> RemoteTrack
var _remotes: Dictionary = {}


func _init() -> void:
	name = NODE_NAME
	set_physics_process(false)


func _exit_tree() -> void:
	detach()


func _physics_process(delta: float) -> void:
	_send_accumulator += delta
	if not _pending.is_empty() and _send_accumulator >= SEND_INTERVAL:
		_send_accumulator = 0.0
		if _can_send() and not _receiving:
			for participant_id: int in _pending.keys():
				_rpc_state.rpc(participant_id, _pending[participant_id])
		_pending.clear()
	for peer_id: int in _remotes.keys():
		var track: RemoteTrack = _remotes[peer_id]
		_advance(track, delta)
		_race.call(METHOD_SET_REMOTE, peer_id, track.current)


## Connects the duck-typed race hooks (docs/ARCHITECTURE.md "Race scene contract") and tells
## the race whether this peer is the authority.
func attach(race: Node) -> void:
	detach()
	_race = race
	_api = multiplayer
	race.connect(SIGNAL_LOCAL_STATE, _on_local_state_updated)
	if is_authority():
		race.connect(SIGNAL_PENALTY, _on_penalty_decided)
		RaceBus.race_phase_changed.connect(_on_phase_changed)
		RaceBus.countdown_tick.connect(_on_countdown_tick)
		RaceBus.car_finished.connect(_on_car_finished)
		RaceBus.race_finished.connect(_on_results)
		RaceBus.car_crushed.connect(_on_crushed)
	_api.peer_disconnected.connect(_on_peer_disconnected)
	race.call(METHOD_SET_AUTHORITY, is_authority())
	set_physics_process(true)


func detach() -> void:
	if _race == null:
		return
	set_physics_process(false)
	_disconnect(_race, SIGNAL_LOCAL_STATE, _on_local_state_updated)
	_disconnect(_race, SIGNAL_PENALTY, _on_penalty_decided)
	_disconnect(RaceBus, RaceBus.race_phase_changed.get_name(), _on_phase_changed)
	_disconnect(RaceBus, RaceBus.countdown_tick.get_name(), _on_countdown_tick)
	_disconnect(RaceBus, RaceBus.car_finished.get_name(), _on_car_finished)
	_disconnect(RaceBus, &"race_finished", _on_results)
	_disconnect(RaceBus, &"car_crushed", _on_crushed)
	_disconnect(_api, _api.peer_disconnected.get_name(), _on_peer_disconnected)
	_race = null
	_pending.clear()
	_remotes.clear()


func is_authority() -> bool:
	return multiplayer.is_server()


func remote_ids() -> Array[int]:
	var ids: Array[int] = []
	for peer_id: int in _remotes.keys():
		ids.append(peer_id)
	return ids


## Latest interpolated packed state of a remote peer; empty when unknown.
func interpolated_state(peer_id: int) -> PackedFloat32Array:
	if not _remotes.has(peer_id):
		return PackedFloat32Array()
	var track: RemoteTrack = _remotes[peer_id]
	return track.current


static func _disconnect(target: Object, signal_name: StringName, callable: Callable) -> void:
	if target.is_connected(signal_name, callable):
		target.disconnect(signal_name, callable)


static func _advance(track: RemoteTrack, delta: float) -> void:
	track.elapsed += delta
	var t: float = clampf(track.elapsed / SEND_INTERVAL, 0.0, 1.0)
	var state: PackedFloat32Array = track.latest.duplicate()
	var previous: PackedFloat32Array = track.previous
	if absf(track.latest[PACKED_Z] - previous[PACKED_Z]) < Z_SNAP_DISTANCE:
		state[PACKED_Z] = lerpf(previous[PACKED_Z], track.latest[PACKED_Z], t)
	state[PACKED_X] = lerpf(previous[PACKED_X], track.latest[PACKED_X], t)
	state[PACKED_ALTITUDE] = lerpf(previous[PACKED_ALTITUDE], track.latest[PACKED_ALTITUDE], t)
	track.current = state


func _can_send() -> bool:
	if _race == null or _api == null or not _api.has_multiplayer_peer():
		return false
	var connected: bool = (
		_api.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	)
	return connected and _api.get_peers().size() > 0


func _race_time() -> float:
	var value: Variant = _race.get(PROPERTY_RACE_TIME)
	if value is float:
		return value
	return 0.0


## A peer may only publish its own id; the authority may publish any (relayed AI, if ever).
func _on_local_state_updated(participant_id: int, packed: PackedFloat32Array) -> void:
	if participant_id != _api.get_unique_id() and not is_authority():
		return
	_pending[participant_id] = packed


## The authority applies its own penalties itself; only remote ids are relayed.
func _on_penalty_decided(participant_id: int, kind: StringName, data: Dictionary) -> void:
	if participant_id == _api.get_unique_id() or not _api.get_peers().has(participant_id):
		return
	_rpc_penalty.rpc_id(participant_id, participant_id, kind, data)


func _on_phase_changed(phase: StringName) -> void:
	_broadcast_phase(phase)


## Countdown ticks re-send the countdown phase with the host clock so clients stay in step.
func _on_countdown_tick(_value: int) -> void:
	_broadcast_phase(Constants.PHASE_COUNTDOWN)


func _broadcast_phase(phase: StringName) -> void:
	if _can_send() and not _receiving:
		if phase == Constants.PHASE_FINISHED:
			return
		var time: float = _race_time()
		if phase == Constants.PHASE_COUNTDOWN:
			time = float(_race.get(&"_countdown_left"))
		_rpc_phase.rpc(phase, time)


func _on_car_finished(participant_id: int, place: int, time: float) -> void:
	if _can_send() and not _receiving:
		_rpc_finish.rpc(participant_id, place, time)


func _on_peer_disconnected(peer_id: int) -> void:
	_remotes.erase(peer_id)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_state(participant_id: int, packed: PackedFloat32Array) -> void:
	var sender: int = _api.get_remote_sender_id()
	if sender != participant_id and sender != Constants.HOST_PEER_ID:
		return
	if _race == null or packed.size() < CarState.FIELD_COUNT:
		return
	if participant_id == _api.get_unique_id():
		return
	if not _remotes.has(participant_id):
		var fresh: RemoteTrack = RemoteTrack.new()
		fresh.previous = packed
		fresh.current = packed
		_remotes[participant_id] = fresh
	var track: RemoteTrack = _remotes[participant_id]
	track.previous = track.current
	track.latest = packed
	track.elapsed = 0.0


@rpc("authority", "call_remote", "reliable")
func _rpc_penalty(participant_id: int, kind: StringName, data: Dictionary) -> void:
	if _race != null:
		_race.call(METHOD_APPLY_PENALTY, participant_id, kind, data)


@rpc("authority", "call_remote", "reliable")
func _rpc_phase(phase: StringName, time: float) -> void:
	if _race != null:
		_receiving = true
		_race.call(METHOD_FORCE_PHASE, phase, time)
		_receiving = false


@rpc("authority", "call_remote", "reliable")
func _rpc_finish(participant_id: int, place: int, time: float) -> void:
	if _race != null:
		_receiving = true
		_race.call(METHOD_FORCE_FINISH, participant_id, place, time)
		_receiving = false


func _on_results(results: Array[Dictionary]) -> void:
	if _can_send() and not _receiving:
		_rpc_results.rpc(results)


func _on_crushed(attacker: int, victim: int) -> void:
	if _can_send() and not _receiving:
		_rpc_crushed.rpc(attacker, victim)


@rpc("authority", "call_remote", "reliable")
func _rpc_results(results: Array[Dictionary]) -> void:
	if _race != null:
		_receiving = true
		_race.call(&"force_results", results)
		_receiving = false


@rpc("authority", "call_remote", "reliable")
func _rpc_crushed(attacker: int, victim: int) -> void:
	if _race != null:
		_receiving = true
		RaceBus.car_crushed.emit(attacker, victim)
		RaceBus.car_landed.emit(attacker, true)
		_receiving = false
